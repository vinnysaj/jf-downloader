Vinnyfin is a simple native video player for Jellyfin servers that is all about durability. Coming from plex where media downloads never worked, to using other Jellyfin players and not being able to close the app to background a download, I vibe coded a solution that is as native and fast as possible! I plan to release this on the App Store very soon too, so others can use this free and simple video player too. It is ideally the best way to connect to your Jellyfin server.

[![xkcd 927: Standards](https://imgs.xkcd.com/comics/standards.png)](https://xkcd.com/927/)

It is yet another Jellyfin player. But I think mine is really good! It doesn't try to do too much, and what it does it tries to be really really good at.

# Sync

The main advantage here is downloading content for offline playback. The original idea of this project was literally just a Jellyfin sync/downloader, but then I thought "why not? lets make this into a player I can share with my friends and family too" and here we are! It has a lot of cool QOL features like smart downloads that auto delete episodes of shows you've watched as you watch them, and downloads newer episodes as your position in the show advances.

This also works with gelato/aiostreams, which is a common setup and is super awesome because it pretty much eliminates the need for transcoding, making downloads incredibly fast. If you kill the app, the downloads resume gracefully the moment you reopen it.

# Files

Your video syncs/downloads land right in your files app too. So you could use this app strictly as a super durable downloader (its main purpose anyway), and bring your own video player. No problem in that either.

# Support

You may create a github issue. No strict requirements for the format, just tell me what's wrong! Or submit a PR. Either works.

# Platforms

Aiming to support all major apple platforms. iOS, iPadOS, tvOS, visionOS

# Privacy

The app only talks to the Jellyfin server you sign in to. There's no analytics, no tracking, no accounts and no servers of my own. Your Jellyfin access token is kept in the Keychain on your device, and signing out removes it. Watch progress for files on your device stays on your device.

# Not affiliated

vinnyfin isn't made by or affiliated with the Jellyfin project, Gelato, Dolby or DTS. Jellyfin is a trademark of its owners; Dolby, Dolby Vision, Dolby Atmos and DTS are trademarks of their owners.

# License

GPL-3.0. See [LICENSE](LICENSE).

vinnyfin is built on open-source software: AetherEngine (LGPL-3.0 with an App Store exception), FFmpeg (LGPL-2.1 or later, dynamically linked), dav1d (BSD-2-Clause), zimg (WTFPL), libzvbi (LGPL-2.1, MIT), dovi_tool's libdovi (MIT), SMBClient (MIT) and Nuke (MIT). Their licenses are in the app under Settings › Acknowledgements and in [Vinnyfin/Licenses](Vinnyfin/Licenses).
