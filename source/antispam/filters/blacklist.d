/**
	Simple IP/word based black list filter.

	Copyright: © 2013 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module antispam.filters.blacklist;

import antispam.antispam;

import std.array;
import std.string;
import std.uni;
import vibe.data.json;
import vibe.inet.message;


class BlackListSpamFilter : SpamFilter {
	private {
		string[] m_blockedIPs;
		bool[string] m_blockedWords;
	}

	@property string id() const { return "blacklist"; }

	void applySettings(Json settings)
	{
		foreach (ip; settings.ips.opt!(Json[]))
			m_blockedIPs ~= ip.get!string;
		foreach (word; settings.words.opt!(Json[]))
			m_blockedWords[word.get!string.toLower()] = true;
	}

	SpamAction determineImmediateSpamStatus(in ref Message art)
	{
		foreach( ip; art.peerAddress )
			foreach( prefix; m_blockedIPs )
				if( ip.startsWith(prefix) )
					return SpamAction.block;

		if (art.headers["Subject"].decodeEncodedWords().containsWords(m_blockedWords))
			return SpamAction.block;
		if (decodeMessage(art.message, art.headers.get("Content-Transfer-Encoding", "")).containsWords(m_blockedWords))
			return SpamAction.block;

		return SpamAction.pass;
	}

	SpamAction determineAsyncSpamStatus(ref const Message)
	{
		return SpamAction.pass;
	}

	void resetClassification()
	{
	}
	
	void classify(in ref Message art, bool spam, bool unclassify = false)
	{
	}
}


private bool containsWords(string str, in bool[string] words)
{
	bool inword = false;
	string wordstart;
	while (!str.empty) {
		auto ch = str.front;
		auto isword = ch.isAlpha() || ch.isNumber();
		if (inword && !isword) {
			if (wordstart[0 .. wordstart.length - str.length].toLower() in words)
				return true;
			inword = false;
		} else if (!inword && isword) {
			wordstart = str;
			inword = true;
		}
		str.popFront();
	}

	return false;
}