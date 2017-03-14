/** Provides a framework for filtering unwanted messages.

	See `filterMessage` for an example that shows the basic steps to use this
	library.

	Copyright: © 2013-2017 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module antispam.antispam;

public import antispam.filter;

import vibe.data.json : Json;
import vibe.core.core : Task, runTask;


/** Encapsulates a multi-stage filter state.

	This class is the typical entry point for users of the library.
*/
final class AntispamState {
	alias FilterFactory = SpamFilter function() @safe;

	private {
		SpamFilter[] m_filters;
		static FilterFactory[string] m_filterFactories;
	}

	@safe:

	/** Registers a new filter type.

		Note that the filter types included with this library are automatically
		registered at startup.
	*/
	static void registerFilter(string filter, FilterFactory factory)
	{
		debug {
			auto f = factory();
			assert(f.id == filter, "Filter ID passed to registerFilter doesn't match ID of created filter.");
		}
		m_filterFactories[filter] = factory;
	}

	/** Returns a JSON configuration object encapsulating the full filter chain.

		The filter list itself, as well as all filter settings are contained in
		this object.
	*/
	Json getConfig()
	const @trusted { // Json not safe for vibe.d < 0.8.0
		Json[] ret;
		foreach (f; m_filters) {
			auto e = Json.emptyObject;
			e["filter"] = f.id;
			e["settings"] = f.getSettings();
			ret ~= e;
		}
		return Json(ret);
	}

	/** Loads a JSON configuration object as output by `getConfig`.
	*/
	void loadConfig(Json config)
	@trusted { // Json not safe for vibe.d < 0.8.0
		switch (config.type) {
			default:
				throw new Exception("Invalid Antispam configuration format. Expected JSON array or object of filter/settings pairs.");
			case Json.Type.null_: return;
			case Json.Type.undefined: return;
			case Json.Type.array:
				foreach (e; config)
					addFilter(e["filter"].get!string, e["settings"]);
				break;
			case Json.Type.object: // legacy format (doesn't guarantee order)
				foreach (string f, settings; config)
					addFilter(f, settings);
				break;
		}
	}

	/** Appends a filter to the filter chain.
	*/
	void addFilter(string filter, Json settings)
	{
		import std.exception : enforce;

		auto pff = filter in m_filterFactories;
		enforce(pff !is null, "Unknown filter ID: "~filter);
		auto f = (*pff)();
		f.applySettings(settings);
		m_filters ~= f;
	}

	/** Determines the immediate spam status of a message.

		The immediate status consists of the combined answer of all
		chained filters based on knowledge that is immediately
		available, which means without blocking I/O operations or
		lengthy CPU calculations.
	*/
	SpamAction determineImmediateStatus(AntispamMessage message)
	{
		bool revoke = false;

		outer:
		foreach (flt; m_filters) {
			final switch (flt.determineImmediateSpamStatus(message)) {
				case SpamAction.amnesty: return SpamAction.amnesty;
				case SpamAction.pass: break;
				case SpamAction.revoke: revoke = true; break;
				case SpamAction.block: return SpamAction.block;
			}
		}

		return revoke ? SpamAction.revoke : SpamAction.pass;
	}

	/** Determines the asynchronous spam status of a message.

		The asynchronous status is based on status information that
		cannot be determined immediately. Examples are querying
		an external server to check an IP address or to confirm
		a CAPTCHA solution.
	*/
	SpamAction determineAsyncStatus(AntispamMessage message, SpamAction immediate_status)
	{
		import std.algorithm.comparison : among;

		if (immediate_status.among(SpamAction.amnesty, SpamAction.block))
			return immediate_status;

		auto status = immediate_status;
		foreach (flt; m_filters) {
			final switch (flt.determineAsyncSpamStatus(message)) {
				case SpamAction.amnesty: return SpamAction.amnesty;
				case SpamAction.pass: break;
				case SpamAction.revoke: status = SpamAction.revoke; break;
				case SpamAction.block: return SpamAction.block;
			}
		}
		return status;
	}
}

/** Default implementation of full message filtering.

	The function invokes each filter in the filter chain and combines the
	results to get a final answer in the for of a `SpamAction` status.

	It first determines the immediate spam status, calling the
	`on_immediate_status` callback with the result. Then it starts a 
	background task to determine the asynchronous state and, if different
	to the immediate status, passes the result to the `on_async_status`
	callback.

	Params:
		on_immediate_status: Callback that is invoked synchronously with the
			immediate spam status as its argument
		on_async_status: Asynchronous callback that gets called if the
			immediate spam status got revoked during the asynchronous
			spam status check
		state: The state object that holds the filter list to apply
		message: The message to filter

	Returns:
		A handle to the background task is returned. This can be used
		to determine if the asynchronous part has finished.
*/
Task filterMessage(alias on_immediate_status, alias on_async_status)(AntispamState state, AntispamMessage message)
{
	auto ss = state.determineImmediateStatus(message);
	on_immediate_status(ss);
	return runTask({
		auto as = state.determineAsyncStatus(message, ss);
		if (ss != as)
			on_async_status(as);
	});
}

///
unittest {
	import vibe.data.json : parseJsonString;
	import std.algorithm.comparison : among;

	void main()
	{
		auto config = parseJsonString(
			`[
				{"filter": "bayes"},
				{"filter": "blacklist",
					"settings": {
						"ips": ["124.51.45.1", "41.23.11.5"]
					}
				}
			]`);

		auto antispam = new AntispamState;
		antispam.loadConfig(config);

		AntispamMessage msg;
		msg.headers["Subject"] = "8uy CH34P V14GR4!!11";
		msg.message = cast(const(ubyte)[])"Just look here: http://bestdrugdealz.c0m";
		msg.peerAddress = ["123.52.433.1", "vps12315.some.provider.n3t"];

		antispam.filterMessage!(
			(status) {
				if (status.among(SpamAction.revoke, SpamAction.block))
					throw new Exception("Your message has been rejected!");
				// otherwise store message...
			},
			(async_status) {
				if (async_status.among!(SpamAction.revoke, SpamAction.block)) {
					// Flag or delete the stored message.
				}
	
				// It could also theoretically happen here that async_status is amnesty
				// or pass, so that a message that was already rejected in the first
				// phase would be accepted in retrospective. You'll have to decides on
				// a per-application basis if it makes sense to support this case, or
				// if immediate rejections always have precedence.
			}
		)(msg);
	}
}


static this()
{
	import antispam.filters.bayes;
	import antispam.filters.blacklist;
	AntispamState.registerFilter("bayes", () => cast(SpamFilter)new BayesSpamFilter);
	AntispamState.registerFilter("blacklist", () => cast(SpamFilter)new BlackListSpamFilter);
}
