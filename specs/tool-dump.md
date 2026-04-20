# Computer Use Tool Dump (Raw)

This file contains the unabridged raw inputs and outputs captured from the actual Computer Use tool calls in this session.

## 1. `get_app_state`

**Input**

```json
{"app":"com.apple.Music"}
```

**Raw Output**

```text
Computer Use state (CUA App Version: 750)
<app_state>
App=com.apple.Music (pid 40054)
Window: "Music", App: Music.
	0 standard window Music, Secondary Actions: Raise
		1 split group
			2 scroll area ID: sidebarScroller, Secondary Actions: Scroll Up, Scroll Down
				3 outline Description: Sidebar, ID: outline
					4 row (selectable) Search
					5 row (selected) Home
					6 row (selectable) Description: Grid view, Value: New
					7 row (selectable) Description: radio, Value: Radio
					8 row (selectable) Library
					9 row (selectable) Description: clock, Value: Recently Added
					10 row (selectable) Description: artist, Value: Artists
					11 row (selectable) Albums
					12 row (selectable) Description: song, Value: Songs
					13 row (selectable) Description: music video, Value: Music Videos
					14 row (selectable) Description: selfie, Value: Made for You
					15 row (selectable, expanded) Value: Playlists, Secondary Actions: Collapse
					16 row (selectable) All Playlists
					17 row (selectable) Description: favourite, Value: Favourite Songs
					18 row (selectable) Romeo Is Dead
					19 row (selectable) 21 Savage Essentials
					20 row (selectable) Anuv Jain Essentials
					21 row (selectable) AP Dhillon Essentials
					22 row (selectable) Ariana Grande Essentials
					23 row (selectable) ATG's playlist
					24 row (selectable) Blue
					25 row (selectable) Blues Guitar Giants On Alligator Records
					26 row (selectable) Description: playlist, Value: Bollywood Hits
					27 row (selectable) Description: playlist, Value: Brent Faiyaz Essentials
					28 row (selectable) Description: playlist, Value: Chill
					29 row (selectable) Description: playlist, Value: Chris Brown Essentials
					30 row (selectable) Diljit Dosanjh Essentials
					31 row (selectable) Drake Essentials
					32 row (selectable) Ed Sheeran Essentials
					33 row (selectable) Ed Sheeran’s Mathematics Tour Set List
					34 row (selectable) Eminem Essentials
					35 row (selectable) Future Essentials
					36 row (selectable) hindi nostalgia
					37 row (selectable) In My Room
					38 row (selectable) Description: playlist, Value: JAŸ-Z Essentials
					39 row (selectable) Description: playlist, Value: Joji Essentials
					40 row (selectable) Lil Wayne Essentials
					41 row (selectable) Logic Essentials
					42 row (selectable) Metro Boomin Essentials
					43 row (selectable) My Shazam Tracks
					44 row (selectable) Nas Essentials
					45 row (selectable) Party All Night with Bollywood
					46 row (selectable) Post Malone Essentials
					47 row (selectable) Description: playlist, Value: R&B Now
					48 row (selectable) Replay 2023
					49 row (selectable) Replay 2024
					50 row (selectable) Description: playlist, Value: RnB for the Soul
					51 row (selectable) Romeo Is High
					52 row (selectable) Sigma
					53 row (selectable) The Travel Playlist (Bollywood)
					54 row (selectable) Description: playlist, Value: The Weeknd Essentials
					55 row (selectable) The Weeknd: Fitness+ Spotlight
					56 row (selectable) Travis Scott Essentials
					57 row (selectable) Ultimate Bollywood
					58 row (selectable) Description: playlist, Value: Your Essentials
				59 scroll bar (settable, float) 0
					60 value indicator (settable, float) 0
					61 increment arrow button
					62 decrement arrow button
					63 increment page button
					64 decrement page button
			65 button Description: Affan The Great, ID: Music.accountButton
			66 splitter (disabled, settable, float) 208
			67 scroll area Secondary Actions: Scroll Up, Scroll Down
				68 collection
					69 section (disabled)
						70 unknown Description: Saiyaara (From "Saiyaara") - Single, ID: Music.shelfItem.AlbumDetailHeaderLockup[id=album-detail-header-1817818677,parentId=album-detail-header-section-1817818677]
							71 text Saiyaara (From "Saiyaara") - Single
							72 button (disabled) Tanishk Bagchi
							73 button (disabled) Arslan Nizami
							74 button (disabled) Faheem Abdullah
							75 button (disabled) Irshad Kamil
							76 text Bollywood · 2025 · ￼ Lossless
							77 button Play
					78 section (disabled)
						79 container Description: Saiyaara (From "Saiyaara"), ID: Music.shelfItem.AlbumTrackLockup[id=track-lockup-1817818677-1817818678,parentId=track-list-1817818677]
							80 button (disabled) Favourite
							81 text Saiyaara (From "Saiyaara") 6:11
							82 button More
					83 section (disabled)
						84 unknown Music.shelfItem.ContainerDetailTracklistFooterLockup[id=tracklist-footer-1817818677,parentId=track-list-section-1817818677]
							85 text 3 June 2025
1 song, 6 minutes
℗ 2025 YRF Music
				86 scroll bar (settable, float) 0
					87 value indicator (settable, float) 0
					88 increment arrow button
					89 decrement arrow button
					90 increment page button
					91 decrement page button
			92 container Description: Mini Player, ID: Music.miniPlayer.contentView[viewState=mini,isPlaying=false]
				93 button Description: do not shuffle, ID: Music.miniPlayer.shuffleButton
				94 button Description: Previous, ID: Music.miniPlayer.leadingTransportControl
				95 button Description: Play, ID: Music.miniPlayer.playbackTransportControl
				96 button Description: Next, ID: Music.miniPlayer.trailingTransportControl
				97 button Description: do not repeat, ID: Music.miniPlayer.repeatButton
				98 container Music.miniPlayer.metadataRegion[state=populated]
					99 button Description: Mini Player Artwork, ID: Music.miniPlayer.artwork
					100 text Value: Saiyaara (From "Saiyaara"), ID: Music.miniPlayer.title
					101 button Description: More, ID: Music.miniPlayer.contextMenu
					102 slider (settable, float) Description: Track Position, Value: 0.008391891891891892, Details: Not Playing, ID: Music.miniPlayer.playbackSlider
				103 button Description: Lyrics, ID: Music.miniPlayer.lyricsButton
				104 button Description: playing next, ID: Music.miniPlayer.queueButton
				105 button Description: Volume, ID: Music.miniPlayer.volumeButton
		106 toolbar
			107 button Description: Go Back, ID: backButton, Secondary Actions: Move next, Remove from toolbar
			108 button Description: Add to Library, ID: downloadBtn, Secondary Actions: Move previous, Move next, Remove from toolbar
			109 button Description: More, ID: moreBtn, Secondary Actions: Move previous, Move next, Remove from toolbar
		110 close button
		111 full screen button Help: this button also has an action to zoom the window, Secondary Actions: zoom the window
		112 minimise button
	113 menu bar
		114 Music
		115 File
		116 Edit
		117 Song
		118 View
		119 Controls
		120 Account
		121 Window
		122 Help

The focused UI element is 1 split group.
</app_state>
```

## 2. `list_apps`

**Input**

```json
{}
```

**Raw Output**

```text
[{"type":"text","text":"Code — com.microsoft.VSCode [running, last-used=2026-04-19, uses=61]\nSystem Settings — com.apple.systempreferences [running, last-used=2026-04-19, uses=19]\nSafari — com.apple.Safari [running, last-used=2026-04-19, uses=10]\nMusic — com.apple.Music [running, last-used=2026-04-19, uses=4]\nFinder — com.apple.finder [running]\nApp Store — com.apple.AppStore [last-used=2026-04-19, uses=2]\nZed — dev.zed.Zed [last-used=2026-04-11, uses=1]"}]
```

## 3. `click`

**Input**

```json
{"app":"com.apple.Music","element_index":"4"}
```

**Raw Output**

```text
App=com.apple.Music (pid 40054)
Window: "Music", App: Music.
	0 standard window Music, Secondary Actions: Raise
		1 split group
			2 scroll area ID: sidebarScroller, Secondary Actions: Scroll Up, Scroll Down
				3 outline Description: Sidebar, ID: outline
					4 row (selected) Search
					5 row (selectable) Home
					6 row (selectable) Description: Grid view, Value: New
					7 row (selectable) Description: radio, Value: Radio
					8 row (selectable) Library
					9 row (selectable) Description: clock, Value: Recently Added
					10 row (selectable) Description: artist, Value: Artists
					11 row (selectable) Albums
					12 row (selectable) Description: song, Value: Songs
					13 row (selectable) Description: music video, Value: Music Videos
					14 row (selectable) Description: selfie, Value: Made for You
					15 row (selectable, expanded) Value: Playlists, Secondary Actions: Collapse
					16 row (selectable) All Playlists
					17 row (selectable) Description: favourite, Value: Favourite Songs
					18 row (selectable) Romeo Is Dead
					19 row (selectable) 21 Savage Essentials
					20 row (selectable) Anuv Jain Essentials
					21 row (selectable) AP Dhillon Essentials
					22 row (selectable) Ariana Grande Essentials
					23 row (selectable) ATG's playlist
					24 row (selectable) Blue
					25 row (selectable) Blues Guitar Giants On Alligator Records
					26 row (selectable) Description: playlist, Value: Bollywood Hits
					27 row (selectable) Description: playlist, Value: Brent Faiyaz Essentials
					28 row (selectable) Description: playlist, Value: Chill
					29 row (selectable) Description: playlist, Value: Chris Brown Essentials
					30 row (selectable) Diljit Dosanjh Essentials
					31 row (selectable) Drake Essentials
					32 row (selectable) Ed Sheeran Essentials
					33 row (selectable) Ed Sheeran’s Mathematics Tour Set List
					34 row (selectable) Eminem Essentials
					35 row (selectable) Future Essentials
					36 row (selectable) hindi nostalgia
					37 row (selectable) In My Room
					38 row (selectable) Description: playlist, Value: JAŸ-Z Essentials
					39 row (selectable) Description: playlist, Value: Joji Essentials
					40 row (selectable) Lil Wayne Essentials
					41 row (selectable) Logic Essentials
					42 row (selectable) Metro Boomin Essentials
					43 row (selectable) My Shazam Tracks
					44 row (selectable) Nas Essentials
					45 row (selectable) Party All Night with Bollywood
					46 row (selectable) Post Malone Essentials
					47 row (selectable) Description: playlist, Value: R&B Now
					48 row (selectable) Replay 2023
					49 row (selectable) Replay 2024
					50 row (selectable) Description: playlist, Value: RnB for the Soul
					51 row (selectable) Romeo Is High
					52 row (selectable) Sigma
					53 row (selectable) The Travel Playlist (Bollywood)
					54 row (selectable) Description: playlist, Value: The Weeknd Essentials
					55 row (selectable) The Weeknd: Fitness+ Spotlight
					56 row (selectable) Travis Scott Essentials
					57 row (selectable) Ultimate Bollywood
					58 row (selectable) Description: playlist, Value: Your Essentials
				59 scroll bar (settable, float) 0
					60 value indicator (settable, float) 0
					61 increment arrow button
					62 decrement arrow button
					63 increment page button
					64 decrement page button
			65 button Description: Affan The Great, ID: Music.accountButton
			66 splitter (disabled, settable, float) 208
			67 scroll area Secondary Actions: Scroll Up, Scroll Down
				68 collection
					69 section (disabled) Browse Categories
						70 unknown Description: Browse Categories, ID: Music.shelf.header[parentId=browse-category-bricks,itemCount=52,itemKind=searchLandingBrickLockup]
						71 cell Description: Shaadi Mubarak, ID: Music.shelfItem.SearchLandingBrickLockup[id=brick-lockup-6445791093,parentId=browse-category-bricks]
							72 text Shaadi Mubarak
						73 cell Description: Apple Music Pop, ID: Music.shelfItem.SearchLandingBrickLockup[id=brick-lockup-976439548,parentId=browse-category-bricks]
							74 text Pop
						75 cell Description: Apple Music Bollywood, ID: Music.shelfItem.SearchLandingBrickLockup[id=brick-lockup-982307152,parentId=browse-category-bricks]
							76 text Bollywood
						77 cell Description: Concerts, ID: Music.shelfItem.SearchLandingBrickLockup[id=brick-lockup-6758165244,parentId=browse-category-bricks]
							78 text Concerts
						79 cell Description: Apple Music Live, ID: Music.shelfItem.SearchLandingBrickLockup[id=brick-lockup-1649426593,parentId=browse-category-bricks]
							80 text Apple Music Live
						81 cell Description: Replay Monthly, ID: Music.shelfItem.SearchLandingBrickLockup[id=brick-lockup-6444321639,parentId=browse-category-bricks]
							82 text Replay Monthly
						83 cell Description: Charts, ID: Music.shelfItem.SearchLandingBrickLockup[id=brick-lockup-1514706977,parentId=browse-category-bricks]
							84 text Charts
						85 cell Description: Sing, ID: Music.shelfItem.SearchLandingBrickLockup[id=brick-lockup-1710452798,parentId=browse-category-bricks]
							86 text Sing
						87 cell Description: Apple Music Punjabi, ID: Music.shelfItem.SearchLandingBrickLockup[id=brick-lockup-1109031457,parentId=browse-category-bricks]
							88 text Punjabi
						89 cell Description: Apple Music Radio, ID: Music.shelfItem.SearchLandingBrickLockup[id=brick-lockup-1531543191,parentId=browse-category-bricks]
							90 text Apple Music Radio
						91 cell Description: Apple Music Hip-Hop/Rap, ID: Music.shelfItem.SearchLandingBrickLockup[id=brick-lockup-989061415,parentId=browse-category-bricks]
							92 text Hip-Hop/Rap
						93 cell Description: Live Music, ID: Music.shelfItem.SearchLandingBrickLockup[id=brick-lockup-1526866649,parentId=browse-category-bricks]
							94 text Live Music
						95 cell Description: Apple Music Tamil, ID: Music.shelfItem.SearchLandingBrickLockup[id=brick-lockup-982356297,parentId=browse-category-bricks]
							96 text Tamil
						97 cell Description: Apple Music Kids, ID: Music.shelfItem.SearchLandingBrickLockup[id=brick-lockup-989010186,parentId=browse-category-bricks]
							98 text Kids
						99 cell Description: Apple Music Family, ID: Music.shelfItem.SearchLandingBrickLockup[id=brick-lockup-1555173397,parentId=browse-category-bricks]
							100 text Family
						101 cell Description: Apple Music Up Next, ID: Music.shelfItem.SearchLandingBrickLockup[id=brick-lockup-1532467784,parentId=browse-category-bricks]
							102 text Up Next
						103 cell Description: Apple Music Telugu, ID: Music.shelfItem.SearchLandingBrickLockup[id=brick-lockup-1109030996,parentId=browse-category-bricks]
							104 text Telugu
						105 cell Description: Hey Siri, Play..., ID: Music.shelfItem.SearchLandingBrickLockup[id=brick-lockup-1591134055,parentId=browse-category-bricks]
							106 text Hey Siri, Play...
						107 cell Description: Apple Music Rock, ID: Music.shelfItem.SearchLandingBrickLockup[id=brick-lockup-976439554,parentId=browse-category-bricks]
							108 text Rock
						109 cell Description: Apple Music Indian Independent, ID: Music.shelfItem.SearchLandingBrickLockup[id=brick-lockup-982346165,parentId=browse-category-bricks]
							110 text Indian Independent
				111 scroll bar (settable, float) 0
					112 value indicator (settable, float) 0
					113 increment arrow button
					114 decrement arrow button
					115 increment page button
					116 decrement page button
			117 container Description: Mini Player, ID: Music.miniPlayer.contentView[viewState=mini,isPlaying=false]
				118 button Description: do not shuffle, ID: Music.miniPlayer.shuffleButton
				119 button Description: Previous, ID: Music.miniPlayer.leadingTransportControl
				120 button Description: Play, ID: Music.miniPlayer.playbackTransportControl
				121 button Description: Next, ID: Music.miniPlayer.trailingTransportControl
				122 button Description: do not repeat, ID: Music.miniPlayer.repeatButton
				123 container Music.miniPlayer.metadataRegion[state=populated]
					124 button Description: Mini Player Artwork, ID: Music.miniPlayer.artwork
					125 text Value: Saiyaara (From "Saiyaara"), ID: Music.miniPlayer.title
					126 button Description: Favourite, ID: Music.miniPlayer.favoriteButton
					127 button Description: More, ID: Music.miniPlayer.contextMenu
					128 slider (settable, float) Description: Track Position, Value: 0.008391891891891892, Details: Not Playing, ID: Music.miniPlayer.playbackSlider
				129 button Description: Lyrics, ID: Music.miniPlayer.lyricsButton
				130 button Description: playing next, ID: Music.miniPlayer.queueButton
				131 button Description: Volume, ID: Music.miniPlayer.volumeButton
		132 toolbar
			133 search text field (settable, string) Apple Music
				134 button Search
			135 UIA.Music.Search.Scope
				136 radio button Description: Apple Music, Value: 1
				137 radio button Description: Library, Value: 0
		138 close button
		139 full screen button Help: this button also has an action to zoom the window, Secondary Actions: zoom the window
		140 minimise button
	141 menu bar
		142 Music
		143 File
		144 Edit
		145 Song
		146 View
		147 Controls
		148 Account
		149 Window
		150 Help

The focused UI element is 1 split group.
```

## 4. `set_value`

**Input**

```json
{"app":"com.apple.Music","element_index":"133","value":"Drake"}
```

**Raw Output**

```text
App=com.apple.Music (pid 40054)
Window: "Music", App: Music.
	0 standard window Music, Secondary Actions: Raise
		1 split group
			2 scroll area ID: sidebarScroller, Secondary Actions: Scroll Up, Scroll Down
				3 outline Description: Sidebar, ID: outline
					4 row (selected) Search
					5 row (selectable) Home
					6 row (selectable) Description: Grid view, Value: New
					7 row (selectable) Description: radio, Value: Radio
					8 row (selectable) Library
					9 row (selectable) Description: clock, Value: Recently Added
					10 row (selectable) Description: artist, Value: Artists
					11 row (selectable) Albums
					12 row (selectable) Description: song, Value: Songs
					13 row (selectable) Description: music video, Value: Music Videos
					14 row (selectable) Description: selfie, Value: Made for You
					15 row (selectable, expanded) Value: Playlists, Secondary Actions: Collapse
					16 row (selectable) All Playlists
					17 row (selectable) Description: favourite, Value: Favourite Songs
					18 row (selectable) Romeo Is Dead
					19 row (selectable) 21 Savage Essentials
					20 row (selectable) Anuv Jain Essentials
					21 row (selectable) AP Dhillon Essentials
					22 row (selectable) Ariana Grande Essentials
					23 row (selectable) ATG's playlist
					24 row (selectable) Blue
					25 row (selectable) Blues Guitar Giants On Alligator Records
					26 row (selectable) Description: playlist, Value: Bollywood Hits
					27 row (selectable) Description: playlist, Value: Brent Faiyaz Essentials
					28 row (selectable) Description: playlist, Value: Chill
					29 row (selectable) Description: playlist, Value: Chris Brown Essentials
					30 row (selectable) Diljit Dosanjh Essentials
					31 row (selectable) Drake Essentials
					32 row (selectable) Ed Sheeran Essentials
					33 row (selectable) Ed Sheeran’s Mathematics Tour Set List
					34 row (selectable) Eminem Essentials
					35 row (selectable) Future Essentials
					36 row (selectable) hindi nostalgia
					37 row (selectable) In My Room
					38 row (selectable) Description: playlist, Value: JAŸ-Z Essentials
					39 row (selectable) Description: playlist, Value: Joji Essentials
					40 row (selectable) Lil Wayne Essentials
					41 row (selectable) Logic Essentials
					42 row (selectable) Metro Boomin Essentials
					43 row (selectable) My Shazam Tracks
					44 row (selectable) Nas Essentials
					45 row (selectable) Party All Night with Bollywood
					46 row (selectable) Post Malone Essentials
					47 row (selectable) Description: playlist, Value: R&B Now
					48 row (selectable) Replay 2023
					49 row (selectable) Replay 2024
					50 row (selectable) Description: playlist, Value: RnB for the Soul
					51 row (selectable) Romeo Is High
					52 row (selectable) Sigma
					53 row (selectable) The Travel Playlist (Bollywood)
					54 row (selectable) Description: playlist, Value: The Weeknd Essentials
					55 row (selectable) The Weeknd: Fitness+ Spotlight
					56 row (selectable) Travis Scott Essentials
					57 row (selectable) Ultimate Bollywood
					58 row (selectable) Description: playlist, Value: Your Essentials
				59 scroll bar (settable, float) 0
					60 value indicator (settable, float) 0
					61 increment arrow button
					62 decrement arrow button
					63 increment page button
					64 decrement page button
			65 button Description: Affan The Great, ID: Music.accountButton
			66 splitter (disabled, settable, float) 208
			67 scroll area Secondary Actions: Scroll Up, Scroll Down
				68 collection
					69 section (disabled) Top Results
						70 button Description: Top Results, ID: Music.shelf.header[parentId=top-search-section-top,itemCount=8,itemKind=topSearchLockup]
							71 button (disabled) Top Results
							72 image See More
						73 cell Description: Drake, ID: Music.shelfItem.TopSearchLockup[id=top-search-section-top-271256,parentId=top-search-section-top]
							74 text Drake Artist
						75 cell Description: NOKIA, ID: Music.shelfItem.TopSearchLockup[id=top-search-section-top-1796127375,parentId=top-search-section-top]
							76 text NOKIA ￼ Song · Drake
						77 cell Description: One Dance (feat. Wizkid & Kyla), ID: Music.shelfItem.TopSearchLockup[id=top-search-section-top-1440843496,parentId=top-search-section-top]
							78 text One Dance (feat. Wizkid & Kyla) Song · Drake
						79 cell Description: Drake Essentials, ID: Music.shelfItem.TopSearchLockup[id=top-search-section-top-pl.b8afd0ec852542f785a5f7a4a9a80d6a,parentId=top-search-section-top]
							80 text Drake Essentials Playlist · Apple Music Hip-Hop/Rap
						81 cell Description: Passionfruit, ID: Music.shelfItem.TopSearchLockup[id=top-search-section-top-1440891494,parentId=top-search-section-top]
							82 text Passionfruit ￼ Song · Drake
						83 cell Description: MIA (feat. Drake), ID: Music.shelfItem.TopSearchLockup[id=top-search-section-top-1662168786,parentId=top-search-section-top]
							84 text MIA (feat. Drake) Song · Bad Bunny
						85 cell Description: Fair Trade (feat. Travis Scott), ID: Music.shelfItem.TopSearchLockup[id=top-search-section-top-1584281493,parentId=top-search-section-top]
							86 text Fair Trade (feat. Travis Scott) ￼ Song · Drake
						87 cell Description: God's Plan, ID: Music.shelfItem.TopSearchLockup[id=top-search-section-top-1418213269,parentId=top-search-section-top]
							88 text God's Plan ￼ Song · Drake
					89 section (disabled) Artists
						90 button Description: Artists, ID: Music.shelf.header[parentId=bubble-section-artist,itemCount=50,itemKind=bubbleLockup]
							91 button (disabled) Artists
							92 image See More
						93 cell Description: Drake, ID: Music.shelfItem.BubbleLockup[id=bubble-section-artist-271256,parentId=bubble-section-artist]
							94 text Drake
						95 cell Description: Aubrey Drake Graham, ID: Music.shelfItem.BubbleLockup[id=bubble-section-artist-296887979,parentId=bubble-section-artist]
							96 text Aubrey Drake Graham
						97 cell Description: Drake, ID: Music.shelfItem.BubbleLockup[id=bubble-section-artist-1147300457,parentId=bubble-section-artist]
							98 text Drake
						99 cell Description: drake, ID: Music.shelfItem.BubbleLockup[id=bubble-section-artist-332601109,parentId=bubble-section-artist]
							100 text drake
						101 cell Description: Nick Drake, ID: Music.shelfItem.BubbleLockup[id=bubble-section-artist-1285818,parentId=bubble-section-artist]
							102 text Nick Drake
						103 cell Description: Christopher Drake, ID: Music.shelfItem.BubbleLockup[id=bubble-section-artist-306354512,parentId=bubble-section-artist]
							104 text Christopher Drake
						105 cell Description: Drake, ID: Music.shelfItem.BubbleLockup[id=bubble-section-artist-1603482457,parentId=bubble-section-artist]
							106 text Drake
						107 button (disabled) Previous Page
						108 button (disabled) Next Page
					109 section (disabled) Albums
						110 button Description: Albums, ID: Music.shelf.header[parentId=square-section-album,itemCount=50,itemKind=squareLockup]
							111 button (disabled) Albums
							112 image See More
						113 container Description: MIA (feat. Drake) - Single, ID: Music.shelfItem.SquareLockup[id=square-section-album-1662168785,parentId=square-section-album]
							114 button (disabled) MIA (feat. Drake) - Single
							115 button (disabled) Bad Bunny
						116 container Description: POPSTAR (feat. Drake) - Single, ID: Music.shelfItem.SquareLockup[id=square-section-album-1523923474,parentId=square-section-album]
							117 button (disabled) POPSTAR (feat. Drake) - Single
							118 button (disabled) DJ Khaled
							119 image Description: Explicit, Value: ￼
						120 container Description: Honestly, Nevermind, ID: Music.shelfItem.SquareLockup[id=square-section-album-1630230040,parentId=square-section-album]
							121 button (disabled) Honestly, Nevermind
							122 button (disabled) Drake
							123 image Description: Explicit, Value: ￼
						124 container Description: GREECE (feat. Drake) - Single, ID: Music.shelfItem.SquareLockup[id=square-section-album-1523923810,parentId=square-section-album]
							125 button (disabled) GREECE (feat. Drake) - Single
							126 button (disabled) DJ Khaled
							127 image Description: Explicit, Value: ￼
						128 container Description: Toosie Slide - Single, ID: Music.shelfItem.SquareLockup[id=square-section-album-1505943426,parentId=square-section-album]
							129 button (disabled) Toosie Slide - Single
							130 button (disabled) Drake
							131 image Description: Explicit, Value: ￼
						132 button (disabled) Previous Page
						133 button (disabled) Next Page
				134 scroll bar (settable, float) 0
					135 value indicator (settable, float) 0
					136 increment arrow button
					137 decrement arrow button
					138 increment page button
					139 decrement page button
			140 container Description: Mini Player, ID: Music.miniPlayer.contentView[viewState=mini,isPlaying=false]
				141 button Description: do not shuffle, ID: Music.miniPlayer.shuffleButton
				142 button Description: Previous, ID: Music.miniPlayer.leadingTransportControl
				143 button Description: Play, ID: Music.miniPlayer.playbackTransportControl
				144 button Description: Next, ID: Music.miniPlayer.trailingTransportControl
				145 button Description: do not repeat, ID: Music.miniPlayer.repeatButton
				146 container Music.miniPlayer.metadataRegion[state=populated]
					147 button Description: Mini Player Artwork, ID: Music.miniPlayer.artwork
					148 text Value: Saiyaara (From "Saiyaara"), ID: Music.miniPlayer.title
					149 button Description: Favourite, ID: Music.miniPlayer.favoriteButton
					150 button Description: More, ID: Music.miniPlayer.contextMenu
					151 slider (settable, float) Description: Track Position, Value: 0.008391891891891892, Details: Not Playing, ID: Music.miniPlayer.playbackSlider
				152 button Description: Lyrics, ID: Music.miniPlayer.lyricsButton
				153 button Description: playing next, ID: Music.miniPlayer.queueButton
				154 button Description: Volume, ID: Music.miniPlayer.volumeButton
		155 toolbar
			156 search text field (settable, string) Value: Drake, Placeholder: Apple Music
				157 button Search
				158 button cancel
			159 UIA.Music.Search.Scope
				160 radio button Description: Apple Music, Value: 1
				161 radio button Description: Library, Value: 0
		162 close button
		163 full screen button Help: this button also has an action to zoom the window, Secondary Actions: zoom the window
		164 minimise button
	165 menu bar
		166 Music
		167 File
		168 Edit
		169 Song
		170 View
		171 Controls
		172 Account
		173 Window
		174 Help

Selected text: ```
Drake
```

Note: Pay special attention to the content selected by the user. If the user asks a question or refers to the content they are looking at on-screen, they might be referring to the selected content (but they might be referring to something else that's visible, too).
```

## 5. `type_text`

**Input**

```json
{"app":"com.apple.Music","text":"Drake"}
```

**Raw Output**

```text
App=com.apple.Music (pid 40054)
Window: "Music", App: Music.
	0 standard window Music, Secondary Actions: Raise
		1 split group
			2 scroll area ID: sidebarScroller, Secondary Actions: Scroll Up, Scroll Down
				3 outline Description: Sidebar, ID: outline
					4 row (selected) Search
					5 row (selectable) Home
					6 row (selectable) Description: Grid view, Value: New
					7 row (selectable) Description: radio, Value: Radio
					8 row (selectable) Library
					9 row (selectable) Description: clock, Value: Recently Added
					10 row (selectable) Description: artist, Value: Artists
					11 row (selectable) Albums
					12 row (selectable) Description: song, Value: Songs
					13 row (selectable) Description: music video, Value: Music Videos
					14 row (selectable) Description: selfie, Value: Made for You
					15 row (selectable, expanded) Value: Playlists, Secondary Actions: Collapse
					16 row (selectable) All Playlists
					17 row (selectable) Description: favourite, Value: Favourite Songs
					18 row (selectable) Romeo Is Dead
					19 row (selectable) 21 Savage Essentials
					20 row (selectable) Anuv Jain Essentials
					21 row (selectable) AP Dhillon Essentials
					22 row (selectable) Ariana Grande Essentials
					23 row (selectable) ATG's playlist
					24 row (selectable) Blue
					25 row (selectable) Blues Guitar Giants On Alligator Records
					26 row (selectable) Description: playlist, Value: Bollywood Hits
					27 row (selectable) Description: playlist, Value: Brent Faiyaz Essentials
					28 row (selectable) Description: playlist, Value: Chill
					29 row (selectable) Description: playlist, Value: Chris Brown Essentials
					30 row (selectable) Diljit Dosanjh Essentials
					31 row (selectable) Drake Essentials
					32 row (selectable) Ed Sheeran Essentials
					33 row (selectable) Ed Sheeran’s Mathematics Tour Set List
					34 row (selectable) Eminem Essentials
					35 row (selectable) Future Essentials
					36 row (selectable) hindi nostalgia
					37 row (selectable) In My Room
					38 row (selectable) Description: playlist, Value: JAŸ-Z Essentials
					39 row (selectable) Description: playlist, Value: Joji Essentials
					40 row (selectable) Lil Wayne Essentials
					41 row (selectable) Logic Essentials
					42 row (selectable) Metro Boomin Essentials
					43 row (selectable) My Shazam Tracks
					44 row (selectable) Nas Essentials
					45 row (selectable) Party All Night with Bollywood
					46 row (selectable) Post Malone Essentials
					47 row (selectable) Description: playlist, Value: R&B Now
					48 row (selectable) Replay 2023
					49 row (selectable) Replay 2024
					50 row (selectable) Description: playlist, Value: RnB for the Soul
					51 row (selectable) Romeo Is High
					52 row (selectable) Sigma
					53 row (selectable) The Travel Playlist (Bollywood)
					54 row (selectable) Description: playlist, Value: The Weeknd Essentials
					55 row (selectable) The Weeknd: Fitness+ Spotlight
					56 row (selectable) Travis Scott Essentials
					57 row (selectable) Ultimate Bollywood
					58 row (selectable) Description: playlist, Value: Your Essentials
				59 scroll bar (settable, float) 0
					60 value indicator (settable, float) 0
					61 increment arrow button
					62 decrement arrow button
					63 increment page button
					64 decrement page button
			65 button Description: Affan The Great, ID: Music.accountButton
			66 splitter (disabled, settable, float) 208
			67 scroll area Secondary Actions: Scroll Up, Scroll Down
				68 collection
					69 section (disabled) Top Results
						70 button Description: Top Results, ID: Music.shelf.header[parentId=top-search-section-top,itemCount=8,itemKind=topSearchLockup]
							71 button (disabled) Top Results
							72 image See More
						73 cell Description: Drake, ID: Music.shelfItem.TopSearchLockup[id=top-search-section-top-271256,parentId=top-search-section-top]
							74 text Drake Artist
						75 cell Description: NOKIA, ID: Music.shelfItem.TopSearchLockup[id=top-search-section-top-1796127375,parentId=top-search-section-top]
							76 text NOKIA ￼ Song · Drake
						77 cell Description: One Dance (feat. Wizkid & Kyla), ID: Music.shelfItem.TopSearchLockup[id=top-search-section-top-1440843496,parentId=top-search-section-top]
							78 text One Dance (feat. Wizkid & Kyla) Song · Drake
						79 cell Description: Drake Essentials, ID: Music.shelfItem.TopSearchLockup[id=top-search-section-top-pl.b8afd0ec852542f785a5f7a4a9a80d6a,parentId=top-search-section-top]
							80 text Drake Essentials Playlist · Apple Music Hip-Hop/Rap
						81 cell Description: Passionfruit, ID: Music.shelfItem.TopSearchLockup[id=top-search-section-top-1440891494,parentId=top-search-section-top]
							82 text Passionfruit ￼ Song · Drake
						83 cell Description: MIA (feat. Drake), ID: Music.shelfItem.TopSearchLockup[id=top-search-section-top-1662168786,parentId=top-search-section-top]
							84 text MIA (feat. Drake) Song · Bad Bunny
						85 cell Description: Fair Trade (feat. Travis Scott), ID: Music.shelfItem.TopSearchLockup[id=top-search-section-top-1584281493,parentId=top-search-section-top]
							86 text Fair Trade (feat. Travis Scott) ￼ Song · Drake
						87 cell Description: God's Plan, ID: Music.shelfItem.TopSearchLockup[id=top-search-section-top-1418213269,parentId=top-search-section-top]
							88 text God's Plan ￼ Song · Drake
					89 section (disabled) Artists
						90 button Description: Artists, ID: Music.shelf.header[parentId=bubble-section-artist,itemCount=50,itemKind=bubbleLockup]
							91 button (disabled) Artists
							92 image See More
						93 cell Description: Drake, ID: Music.shelfItem.BubbleLockup[id=bubble-section-artist-271256,parentId=bubble-section-artist]
							94 text Drake
						95 cell Description: Aubrey Drake Graham, ID: Music.shelfItem.BubbleLockup[id=bubble-section-artist-296887979,parentId=bubble-section-artist]
							96 text Aubrey Drake Graham
						97 cell Description: Drake, ID: Music.shelfItem.BubbleLockup[id=bubble-section-artist-1147300457,parentId=bubble-section-artist]
							98 text Drake
						99 cell Description: drake, ID: Music.shelfItem.BubbleLockup[id=bubble-section-artist-332601109,parentId=bubble-section-artist]
							100 text drake
						101 cell Description: Nick Drake, ID: Music.shelfItem.BubbleLockup[id=bubble-section-artist-1285818,parentId=bubble-section-artist]
							102 text Nick Drake
						103 cell Description: Christopher Drake, ID: Music.shelfItem.BubbleLockup[id=bubble-section-artist-306354512,parentId=bubble-section-artist]
							104 text Christopher Drake
						105 cell Description: Drake, ID: Music.shelfItem.BubbleLockup[id=bubble-section-artist-1603482457,parentId=bubble-section-artist]
							106 text Drake
						107 button (disabled) Previous Page
						108 button (disabled) Next Page
					109 section (disabled) Albums
						110 button Description: Albums, ID: Music.shelf.header[parentId=square-section-album,itemCount=50,itemKind=squareLockup]
							111 button (disabled) Albums
							112 image See More
						113 container Description: MIA (feat. Drake) - Single, ID: Music.shelfItem.SquareLockup[id=square-section-album-1662168785,parentId=square-section-album]
							114 button (disabled) MIA (feat. Drake) - Single
							115 button (disabled) Bad Bunny
						116 container Description: POPSTAR (feat. Drake) - Single, ID: Music.shelfItem.SquareLockup[id=square-section-album-1523923474,parentId=square-section-album]
							117 button (disabled) POPSTAR (feat. Drake) - Single
							118 button (disabled) DJ Khaled
							119 image Description: Explicit, Value: ￼
						120 container Description: Honestly, Nevermind, ID: Music.shelfItem.SquareLockup[id=square-section-album-1630230040,parentId=square-section-album]
							121 button (disabled) Honestly, Nevermind
							122 button (disabled) Drake
							123 image Description: Explicit, Value: ￼
						124 container Description: GREECE (feat. Drake) - Single, ID: Music.shelfItem.SquareLockup[id=square-section-album-1523923810,parentId=square-section-album]
							125 button (disabled) GREECE (feat. Drake) - Single
							126 button (disabled) DJ Khaled
							127 image Description: Explicit, Value: ￼
						128 container Description: Toosie Slide - Single, ID: Music.shelfItem.SquareLockup[id=square-section-album-1505943426,parentId=square-section-album]
							129 button (disabled) Toosie Slide - Single
							130 button (disabled) Drake
							131 image Description: Explicit, Value: ￼
						132 button (disabled) Previous Page
						133 button (disabled) Next Page
				134 scroll bar (settable, float) 0
					135 value indicator (settable, float) 0
					136 increment arrow button
					137 decrement arrow button
					138 increment page button
					139 decrement page button
			140 container Description: Mini Player, ID: Music.miniPlayer.contentView[viewState=mini,isPlaying=false]
				141 button Description: do not shuffle, ID: Music.miniPlayer.shuffleButton
				142 button Description: Previous, ID: Music.miniPlayer.leadingTransportControl
				143 button Description: Play, ID: Music.miniPlayer.playbackTransportControl
				144 button Description: Next, ID: Music.miniPlayer.trailingTransportControl
				145 button Description: do not repeat, ID: Music.miniPlayer.repeatButton
				146 container Music.miniPlayer.metadataRegion[state=populated]
					147 button Description: Mini Player Artwork, ID: Music.miniPlayer.artwork
					148 text Value: Saiyaara (From "Saiyaara"), ID: Music.miniPlayer.title
					149 button Description: Favourite, ID: Music.miniPlayer.favoriteButton
					150 button Description: More, ID: Music.miniPlayer.contextMenu
					151 slider (settable, float) Description: Track Position, Value: 0.008391891891891892, Details: Not Playing, ID: Music.miniPlayer.playbackSlider
				152 button Description: Lyrics, ID: Music.miniPlayer.lyricsButton
				153 button Description: playing next, ID: Music.miniPlayer.queueButton
				154 button Description: Volume, ID: Music.miniPlayer.volumeButton
		155 toolbar
			156 search text field (settable, string) Value: Drake, Placeholder: Apple Music
				157 button Search
				158 button cancel
			159 UIA.Music.Search.Scope
				160 radio button Description: Apple Music, Value: 1
				161 radio button Description: Library, Value: 0
		162 close button
		163 full screen button Help: this button also has an action to zoom the window, Secondary Actions: zoom the window
		164 minimise button
	165 menu bar
		166 Music
		167 File
		168 Edit
		169 Song
		170 View
		171 Controls
		172 Account
		173 Window
		174 Help

The focused UI element is 156 search text field.
```

## 6. `press_key`

**Input**

```json
{"app":"com.apple.Music","key":"Escape"}
```

**Raw Output**

```text
App=com.apple.Music (pid 40054)
Window: "Music", App: Music.
	0 standard window Music, Secondary Actions: Raise
		1 split group
			2 scroll area ID: sidebarScroller, Secondary Actions: Scroll Up, Scroll Down
				3 outline Description: Sidebar, ID: outline
					4 row (selected) Search
					5 row (selectable) Home
					6 row (selectable) Description: Grid view, Value: New
					7 row (selectable) Description: radio, Value: Radio
					8 row (selectable) Library
					9 row (selectable) Description: clock, Value: Recently Added
					10 row (selectable) Description: artist, Value: Artists
					11 row (selectable) Albums
					12 row (selectable) Description: song, Value: Songs
					13 row (selectable) Description: music video, Value: Music Videos
					14 row (selectable) Description: selfie, Value: Made for You
					15 row (selectable, expanded) Value: Playlists, Secondary Actions: Collapse
					16 row (selectable) All Playlists
					17 row (selectable) Description: favourite, Value: Favourite Songs
					18 row (selectable) Romeo Is Dead
					19 row (selectable) 21 Savage Essentials
					20 row (selectable) Anuv Jain Essentials
					21 row (selectable) AP Dhillon Essentials
					22 row (selectable) Ariana Grande Essentials
					23 row (selectable) ATG's playlist
					24 row (selectable) Blue
					25 row (selectable) Blues Guitar Giants On Alligator Records
					26 row (selectable) Description: playlist, Value: Bollywood Hits
					27 row (selectable) Description: playlist, Value: Brent Faiyaz Essentials
					28 row (selectable) Description: playlist, Value: Chill
					29 row (selectable) Description: playlist, Value: Chris Brown Essentials
					30 row (selectable) Diljit Dosanjh Essentials
					31 row (selectable) Drake Essentials
					32 row (selectable) Ed Sheeran Essentials
					33 row (selectable) Ed Sheeran’s Mathematics Tour Set List
					34 row (selectable) Eminem Essentials
					35 row (selectable) Future Essentials
					36 row (selectable) hindi nostalgia
					37 row (selectable) In My Room
					38 row (selectable) Description: playlist, Value: JAŸ-Z Essentials
					39 row (selectable) Description: playlist, Value: Joji Essentials
					40 row (selectable) Lil Wayne Essentials
					41 row (selectable) Logic Essentials
					42 row (selectable) Metro Boomin Essentials
					43 row (selectable) My Shazam Tracks
					44 row (selectable) Nas Essentials
					45 row (selectable) Party All Night with Bollywood
					46 row (selectable) Post Malone Essentials
					47 row (selectable) Description: playlist, Value: R&B Now
					48 row (selectable) Replay 2023
					49 row (selectable) Replay 2024
					50 row (selectable) Description: playlist, Value: RnB for the Soul
					51 row (selectable) Romeo Is High
					52 row (selectable) Sigma
					53 row (selectable) The Travel Playlist (Bollywood)
					54 row (selectable) Description: playlist, Value: The Weeknd Essentials
					55 row (selectable) The Weeknd: Fitness+ Spotlight
					56 row (selectable) Travis Scott Essentials
					57 row (selectable) Ultimate Bollywood
					58 row (selectable) Description: playlist, Value: Your Essentials
				59 scroll bar (settable, float) 0
					60 value indicator (settable, float) 0
					61 increment arrow button
					62 decrement arrow button
					63 increment page button
					64 decrement page button
			65 button Description: Affan The Great, ID: Music.accountButton
			66 splitter (disabled, settable, float) 208
			67 scroll area Secondary Actions: Scroll Up, Scroll Down
				68 collection
					69 section (disabled) Top Results
						70 button Description: Top Results, ID: Music.shelf.header[parentId=top-search-section-top,itemCount=8,itemKind=topSearchLockup]
							71 button (disabled) Top Results
							72 image See More
						73 cell Description: Drake, ID: Music.shelfItem.TopSearchLockup[id=top-search-section-top-271256,parentId=top-search-section-top]
							74 text Drake Artist
						75 cell Description: NOKIA, ID: Music.shelfItem.TopSearchLockup[id=top-search-section-top-1796127375,parentId=top-search-section-top]
							76 text NOKIA ￼ Song · Drake
						77 cell Description: One Dance (feat. Wizkid & Kyla), ID: Music.shelfItem.TopSearchLockup[id=top-search-section-top-1440843496,parentId=top-search-section-top]
							78 text One Dance (feat. Wizkid & Kyla) Song · Drake
						79 cell Description: Drake Essentials, ID: Music.shelfItem.TopSearchLockup[id=top-search-section-top-pl.b8afd0ec852542f785a5f7a4a9a80d6a,parentId=top-search-section-top]
							80 text Drake Essentials Playlist · Apple Music Hip-Hop/Rap
						81 cell Description: Passionfruit, ID: Music.shelfItem.TopSearchLockup[id=top-search-section-top-1440891494,parentId=top-search-section-top]
							82 text Passionfruit ￼ Song · Drake
						83 cell Description: MIA (feat. Drake), ID: Music.shelfItem.TopSearchLockup[id=top-search-section-top-1662168786,parentId=top-search-section-top]
							84 text MIA (feat. Drake) Song · Bad Bunny
						85 cell Description: Fair Trade (feat. Travis Scott), ID: Music.shelfItem.TopSearchLockup[id=top-search-section-top-1584281493,parentId=top-search-section-top]
							86 text Fair Trade (feat. Travis Scott) ￼ Song · Drake
						87 cell Description: God's Plan, ID: Music.shelfItem.TopSearchLockup[id=top-search-section-top-1418213269,parentId=top-search-section-top]
							88 text God's Plan ￼ Song · Drake
					89 section (disabled) Artists
						90 button Description: Artists, ID: Music.shelf.header[parentId=bubble-section-artist,itemCount=50,itemKind=bubbleLockup]
							91 button (disabled) Artists
							92 image See More
						93 cell Description: Drake, ID: Music.shelfItem.BubbleLockup[id=bubble-section-artist-271256,parentId=bubble-section-artist]
							94 text Drake
						95 cell Description: Aubrey Drake Graham, ID: Music.shelfItem.BubbleLockup[id=bubble-section-artist-296887979,parentId=bubble-section-artist]
							96 text Aubrey Drake Graham
						97 cell Description: Drake, ID: Music.shelfItem.BubbleLockup[id=bubble-section-artist-1147300457,parentId=bubble-section-artist]
							98 text Drake
						99 cell Description: drake, ID: Music.shelfItem.BubbleLockup[id=bubble-section-artist-332601109,parentId=bubble-section-artist]
							100 text drake
						101 cell Description: Nick Drake, ID: Music.shelfItem.BubbleLockup[id=bubble-section-artist-1285818,parentId=bubble-section-artist]
							102 text Nick Drake
						103 cell Description: Christopher Drake, ID: Music.shelfItem.BubbleLockup[id=bubble-section-artist-306354512,parentId=bubble-section-artist]
							104 text Christopher Drake
						105 cell Description: Drake, ID: Music.shelfItem.BubbleLockup[id=bubble-section-artist-1603482457,parentId=bubble-section-artist]
							106 text Drake
						107 button (disabled) Previous Page
						108 button (disabled) Next Page
					109 section (disabled) Albums
						110 button Description: Albums, ID: Music.shelf.header[parentId=square-section-album,itemCount=50,itemKind=squareLockup]
							111 button (disabled) Albums
							112 image See More
						113 container Description: MIA (feat. Drake) - Single, ID: Music.shelfItem.SquareLockup[id=square-section-album-1662168785,parentId=square-section-album]
							114 button (disabled) MIA (feat. Drake) - Single
							115 button (disabled) Bad Bunny
						116 container Description: POPSTAR (feat. Drake) - Single, ID: Music.shelfItem.SquareLockup[id=square-section-album-1523923474,parentId=square-section-album]
							117 button (disabled) POPSTAR (feat. Drake) - Single
							118 button (disabled) DJ Khaled
							119 image Description: Explicit, Value: ￼
						120 container Description: Honestly, Nevermind, ID: Music.shelfItem.SquareLockup[id=square-section-album-1630230040,parentId=square-section-album]
							121 button (disabled) Honestly, Nevermind
							122 button (disabled) Drake
							123 image Description: Explicit, Value: ￼
						124 container Description: GREECE (feat. Drake) - Single, ID: Music.shelfItem.SquareLockup[id=square-section-album-1523923810,parentId=square-section-album]
							125 button (disabled) GREECE (feat. Drake) - Single
							126 button (disabled) DJ Khaled
							127 image Description: Explicit, Value: ￼
						128 container Description: Toosie Slide - Single, ID: Music.shelfItem.SquareLockup[id=square-section-album-1505943426,parentId=square-section-album]
							129 button (disabled) Toosie Slide - Single
							130 button (disabled) Drake
							131 image Description: Explicit, Value: ￼
						132 button (disabled) Previous Page
						133 button (disabled) Next Page
				134 scroll bar (settable, float) 0
					135 value indicator (settable, float) 0
					136 increment arrow button
					137 decrement arrow button
					138 increment page button
					139 decrement page button
			140 container Description: Mini Player, ID: Music.miniPlayer.contentView[viewState=mini,isPlaying=false]
				141 button Description: do not shuffle, ID: Music.miniPlayer.shuffleButton
				142 button Description: Previous, ID: Music.miniPlayer.leadingTransportControl
				143 button Description: Play, ID: Music.miniPlayer.playbackTransportControl
				144 button Description: Next, ID: Music.miniPlayer.trailingTransportControl
				145 button Description: do not repeat, ID: Music.miniPlayer.repeatButton
				146 container Music.miniPlayer.metadataRegion[state=populated]
					147 button Description: Mini Player Artwork, ID: Music.miniPlayer.artwork
					148 text Value: Saiyaara (From "Saiyaara"), ID: Music.miniPlayer.title
					149 button Description: Favourite, ID: Music.miniPlayer.favoriteButton
					150 button Description: More, ID: Music.miniPlayer.contextMenu
					151 slider (settable, float) Description: Track Position, Value: 0.008391891891891892, Details: Not Playing, ID: Music.miniPlayer.playbackSlider
					152 text 0:03
					153 button ‎−6:07
				154 button Description: Lyrics, ID: Music.miniPlayer.lyricsButton
				155 button Description: playing next, ID: Music.miniPlayer.queueButton
				156 button Description: Volume, ID: Music.miniPlayer.volumeButton
		157 toolbar
			158 search text field (settable, string) Value: Drake, Placeholder: Apple Music
				159 button Search
				160 button cancel
			161 UIA.Music.Search.Scope
				162 radio button Description: Apple Music, Value: 1
				163 radio button Description: Library, Value: 0
		164 close button
		165 full screen button Help: this button also has an action to zoom the window, Secondary Actions: zoom the window
		166 minimise button
	167 menu bar
		168 Music
		169 File
		170 Edit
		171 Song
		172 View
		173 Controls
		174 Account
		175 Window
		176 Help

The focused UI element is 158 search text field.
```

## 7. `scroll`

**Input**

```json
{"app":"com.apple.Music","element_index":"67","direction":"down","pages":1}
```

**Raw Output**

```text
App=com.apple.Music (pid 40054)
Window: "Music", App: Music.
	0 standard window Music, Secondary Actions: Raise
		1 split group
			2 scroll area ID: sidebarScroller, Secondary Actions: Scroll Up, Scroll Down
				3 outline Description: Sidebar, ID: outline
					4 row (selected) Search
					5 row (selectable) Home
					6 row (selectable) Description: Grid view, Value: New
					7 row (selectable) Description: radio, Value: Radio
					8 row (selectable) Library
					9 row (selectable) Description: clock, Value: Recently Added
					10 row (selectable) Description: artist, Value: Artists
					11 row (selectable) Albums
					12 row (selectable) Description: song, Value: Songs
					13 row (selectable) Description: music video, Value: Music Videos
					14 row (selectable) Description: selfie, Value: Made for You
					15 row (selectable, expanded) Value: Playlists, Secondary Actions: Collapse
					16 row (selectable) All Playlists
					17 row (selectable) Description: favourite, Value: Favourite Songs
					18 row (selectable) Romeo Is Dead
					19 row (selectable) 21 Savage Essentials
					20 row (selectable) Anuv Jain Essentials
					21 row (selectable) AP Dhillon Essentials
					22 row (selectable) Ariana Grande Essentials
					23 row (selectable) ATG's playlist
					24 row (selectable) Blue
					25 row (selectable) Blues Guitar Giants On Alligator Records
					26 row (selectable) Description: playlist, Value: Bollywood Hits
					27 row (selectable) Description: playlist, Value: Brent Faiyaz Essentials
					28 row (selectable) Description: playlist, Value: Chill
					29 row (selectable) Description: playlist, Value: Chris Brown Essentials
					30 row (selectable) Diljit Dosanjh Essentials
					31 row (selectable) Drake Essentials
					32 row (selectable) Ed Sheeran Essentials
					33 row (selectable) Ed Sheeran’s Mathematics Tour Set List
					34 row (selectable) Eminem Essentials
					35 row (selectable) Future Essentials
					36 row (selectable) hindi nostalgia
					37 row (selectable) In My Room
					38 row (selectable) Description: playlist, Value: JAŸ-Z Essentials
					39 row (selectable) Description: playlist, Value: Joji Essentials
					40 row (selectable) Lil Wayne Essentials
					41 row (selectable) Logic Essentials
					42 row (selectable) Metro Boomin Essentials
					43 row (selectable) My Shazam Tracks
					44 row (selectable) Nas Essentials
					45 row (selectable) Party All Night with Bollywood
					46 row (selectable) Post Malone Essentials
					47 row (selectable) Description: playlist, Value: R&B Now
					48 row (selectable) Replay 2023
					49 row (selectable) Replay 2024
					50 row (selectable) Description: playlist, Value: RnB for the Soul
					51 row (selectable) Romeo Is High
					52 row (selectable) Sigma
					53 row (selectable) The Travel Playlist (Bollywood)
					54 row (selectable) Description: playlist, Value: The Weeknd Essentials
					55 row (selectable) The Weeknd: Fitness+ Spotlight
					56 row (selectable) Travis Scott Essentials
					57 row (selectable) Ultimate Bollywood
					58 row (selectable) Description: playlist, Value: Your Essentials
				59 scroll bar (settable, float) 0
					60 value indicator (settable, float) 0
					61 increment arrow button
					62 decrement arrow button
					63 increment page button
					64 decrement page button
			65 button Description: Affan The Great, ID: Music.accountButton
			66 splitter (disabled, settable, float) 208
			67 scroll area Secondary Actions: Scroll Up, Scroll Down
				68 collection
					69 section (disabled)
						70 container Description: Drake Essentials, ID: Music.shelfItem.SquareLockup[id=square-section-playlist-pl.b8afd0ec852542f785a5f7a4a9a80d6a,parentId=square-section-playlist]
							71 button (disabled) Drake Essentials
						72 container Description: Drake: Chill, ID: Music.shelfItem.SquareLockup[id=square-section-playlist-pl.e5bc0180234b40639b5fb6aeb3c6ff68,parentId=square-section-playlist]
							73 button (disabled) Drake: Chill
						74 container Description: Drake: Deep Cuts, ID: Music.shelfItem.SquareLockup[id=square-section-playlist-pl.9c2961c0bd034974a954fa788f7eac3b,parentId=square-section-playlist]
							75 button (disabled) Drake: Deep Cuts
						76 container Description: Drake: Love Songs, ID: Music.shelfItem.SquareLockup[id=square-section-playlist-pl.34a41c73937e4994a8a5cdc243e917cc,parentId=square-section-playlist]
							77 button (disabled) Drake: Love Songs
						78 container Description: Drake’s The Anita Max Win Tour Set List, ID: Music.shelfItem.SquareLockup[id=square-section-playlist-pl.9e6d4fbb09f34aeeb4024414e8c3f4b0,parentId=square-section-playlist]
							79 button (disabled) Drake’s The Anita Max Win Tour Set List
						80 button (disabled) Previous Page
						81 button (disabled) Next Page
					82 section (disabled) Radio Shows
						83 button Description: Radio Shows, ID: Music.shelf.header[parentId=square-section-radio_show,itemCount=2,itemKind=squareLockup]
						84 container Description: OVO SOUND RADIO, ID: Music.shelfItem.SquareLockup[id=square-section-radio_show-993270827,parentId=square-section-radio_show]
							85 button (disabled) OVO SOUND RADIO
						86 container Description: FREEBANDZ RADIO, ID: Music.shelfItem.SquareLockup[id=square-section-radio_show-1203923193,parentId=square-section-radio_show]
							87 button (disabled) FREEBANDZ RADIO
						88 button (disabled) Previous Page
						89 button (disabled) Next Page
					90 section (disabled) Radio Episodes
						91 button Description: Radio Episodes, ID: Music.shelf.header[parentId=square-section-radio_episode,itemCount=50,itemKind=squareLockup]
							92 button (disabled) Radio Episodes
							93 image See More
						94 container Description: Drake, ID: Music.shelfItem.SquareLockup[id=square-section-radio_episode-ra.1691953746,parentId=square-section-radio_episode]
							95 image Description: Explicit, Value: ￼
						96 container Description: Drake, ID: Music.shelfItem.SquareLockup[id=square-section-radio_episode-ra.1555122562,parentId=square-section-radio_episode]
						97 container Description: Drake, ID: Music.shelfItem.SquareLockup[id=square-section-radio_episode-ra.1149151498,parentId=square-section-radio_episode]
						98 container Description: Drake, ID: Music.shelfItem.SquareLockup[id=square-section-radio_episode-ra.1716594328,parentId=square-section-radio_episode]
						99 container Description: Drake, ID: Music.shelfItem.SquareLockup[id=square-section-radio_episode-ra.1759413581,parentId=square-section-radio_episode]
						100 button (disabled) Previous Page
						101 button (disabled) Next Page
				102 scroll bar (settable, float) 0.4638577502899111
					103 value indicator (settable, float) 0.4638577502899111
					104 increment arrow button
					105 decrement arrow button
					106 increment page button
					107 decrement page button
			108 container Description: Mini Player, ID: Music.miniPlayer.contentView[viewState=mini,isPlaying=false]
				109 button Description: do not shuffle, ID: Music.miniPlayer.shuffleButton
				110 button Description: Previous, ID: Music.miniPlayer.leadingTransportControl
				111 button Description: Play, ID: Music.miniPlayer.playbackTransportControl
				112 button Description: Next, ID: Music.miniPlayer.trailingTransportControl
				113 button Description: do not repeat, ID: Music.miniPlayer.repeatButton
				114 container Music.miniPlayer.metadataRegion[state=populated]
					115 button Description: Mini Player Artwork, ID: Music.miniPlayer.artwork
					116 text Value: Saiyaara (From "Saiyaara"), ID: Music.miniPlayer.title
					117 button Description: Favourite, ID: Music.miniPlayer.favoriteButton
					118 button Description: More, ID: Music.miniPlayer.contextMenu
					119 slider (settable, float) Description: Track Position, Value: 0.008391891891891892, Details: Not Playing, ID: Music.miniPlayer.playbackSlider
				120 button Description: Lyrics, ID: Music.miniPlayer.lyricsButton
				121 button Description: playing next, ID: Music.miniPlayer.queueButton
				122 button Description: Volume, ID: Music.miniPlayer.volumeButton
		123 toolbar
			124 search text field (settable, string) Value: Drake, Placeholder: Apple Music
				125 button Search
				126 button cancel
			127 UIA.Music.Search.Scope
				128 radio button Description: Apple Music, Value: 1
				129 radio button Description: Library, Value: 0
		130 close button
		131 full screen button Help: this button also has an action to zoom the window, Secondary Actions: zoom the window
		132 minimise button
	133 menu bar
		134 Music
		135 File
		136 Edit
		137 Song
		138 View
		139 Controls
		140 Account
		141 Window
		142 Help

The focused UI element is 124 search text field.
```

## 8. `perform_secondary_action`

**Input**

```json
{"app":"com.apple.Music","element_index":"67","action":"Scroll Up"}
```

**Raw Output**

```text
App=com.apple.Music (pid 40054)
Window: "Music", App: Music.
	0 standard window Music, Secondary Actions: Raise
		1 split group
			2 scroll area ID: sidebarScroller, Secondary Actions: Scroll Up, Scroll Down
				3 outline Description: Sidebar, ID: outline
					4 row (selected) Search
					5 row (selectable) Home
					6 row (selectable) Description: Grid view, Value: New
					7 row (selectable) Description: radio, Value: Radio
					8 row (selectable) Library
					9 row (selectable) Description: clock, Value: Recently Added
					10 row (selectable) Description: artist, Value: Artists
					11 row (selectable) Albums
					12 row (selectable) Description: song, Value: Songs
					13 row (selectable) Description: music video, Value: Music Videos
					14 row (selectable) Description: selfie, Value: Made for You
					15 row (selectable, expanded) Value: Playlists, Secondary Actions: Collapse
					16 row (selectable) All Playlists
					17 row (selectable) Description: favourite, Value: Favourite Songs
					18 row (selectable) Romeo Is Dead
					19 row (selectable) 21 Savage Essentials
					20 row (selectable) Anuv Jain Essentials
					21 row (selectable) AP Dhillon Essentials
					22 row (selectable) Ariana Grande Essentials
					23 row (selectable) ATG's playlist
					24 row (selectable) Blue
					25 row (selectable) Blues Guitar Giants On Alligator Records
					26 row (selectable) Description: playlist, Value: Bollywood Hits
					27 row (selectable) Description: playlist, Value: Brent Faiyaz Essentials
					28 row (selectable) Description: playlist, Value: Chill
					29 row (selectable) Description: playlist, Value: Chris Brown Essentials
					30 row (selectable) Diljit Dosanjh Essentials
					31 row (selectable) Drake Essentials
					32 row (selectable) Ed Sheeran Essentials
					33 row (selectable) Ed Sheeran’s Mathematics Tour Set List
					34 row (selectable) Eminem Essentials
					35 row (selectable) Future Essentials
					36 row (selectable) hindi nostalgia
					37 row (selectable) In My Room
					38 row (selectable) Description: playlist, Value: JAŸ-Z Essentials
					39 row (selectable) Description: playlist, Value: Joji Essentials
					40 row (selectable) Lil Wayne Essentials
					41 row (selectable) Logic Essentials
					42 row (selectable) Metro Boomin Essentials
					43 row (selectable) My Shazam Tracks
					44 row (selectable) Nas Essentials
					45 row (selectable) Party All Night with Bollywood
					46 row (selectable) Post Malone Essentials
					47 row (selectable) Description: playlist, Value: R&B Now
					48 row (selectable) Replay 2023
					49 row (selectable) Replay 2024
					50 row (selectable) Description: playlist, Value: RnB for the Soul
					51 row (selectable) Romeo Is High
					52 row (selectable) Sigma
					53 row (selectable) The Travel Playlist (Bollywood)
					54 row (selectable) Description: playlist, Value: The Weeknd Essentials
					55 row (selectable) The Weeknd: Fitness+ Spotlight
					56 row (selectable) Travis Scott Essentials
					57 row (selectable) Ultimate Bollywood
					58 row (selectable) Description: playlist, Value: Your Essentials
				59 scroll bar (settable, float) 0
					60 value indicator (settable, float) 0
					61 increment arrow button
					62 decrement arrow button
					63 increment page button
					64 decrement page button
			65 button Description: Affan The Great, ID: Music.accountButton
			66 splitter (disabled, settable, float) 208
			67 scroll area Secondary Actions: Scroll Up, Scroll Down
				68 collection
					69 section (disabled)
						70 container Description: MIA (feat. Drake) - Single, ID: Music.shelfItem.SquareLockup[id=square-section-album-1662168785,parentId=square-section-album]
							71 button (disabled) MIA (feat. Drake) - Single
							72 button (disabled) Bad Bunny
						73 container Description: POPSTAR (feat. Drake) - Single, ID: Music.shelfItem.SquareLockup[id=square-section-album-1523923474,parentId=square-section-album]
							74 button (disabled) POPSTAR (feat. Drake) - Single
							75 button (disabled) DJ Khaled
							76 image Description: Explicit, Value: ￼
						77 container Description: Honestly, Nevermind, ID: Music.shelfItem.SquareLockup[id=square-section-album-1630230040,parentId=square-section-album]
							78 button (disabled) Honestly, Nevermind
							79 button (disabled) Drake
							80 image Description: Explicit, Value: ￼
						81 container Description: GREECE (feat. Drake) - Single, ID: Music.shelfItem.SquareLockup[id=square-section-album-1523923810,parentId=square-section-album]
							82 button (disabled) GREECE (feat. Drake) - Single
							83 button (disabled) DJ Khaled
							84 image Description: Explicit, Value: ￼
						85 container Description: Toosie Slide - Single, ID: Music.shelfItem.SquareLockup[id=square-section-album-1505943426,parentId=square-section-album]
							86 button (disabled) Toosie Slide - Single
							87 button (disabled) Drake
							88 image Description: Explicit, Value: ￼
						89 button (disabled) Previous Page
						90 button (disabled) Next Page
					91 section (disabled) Songs
						92 button Description: Songs, ID: Music.shelf.header[parentId=track-section-song,itemCount=50,itemKind=trackLockup]
							93 button (disabled) Songs
							94 image See More
						95 container Description: NOKIA, ID: Music.shelfItem.TrackLockup[id=track-section-song-1796127375,parentId=track-section-song]
							96 text NOKIA ￼
							97 button (disabled) Drake
							98 button More
						99 container Description: MIA (feat. Drake), ID: Music.shelfItem.TrackLockup[id=track-section-song-1662168786,parentId=track-section-song]
							100 text MIA (feat. Drake)
							101 button (disabled) Bad Bunny
							102 button More
						103 container Description: Jimmy Cooks (feat. 21 Savage), ID: Music.shelfItem.TrackLockup[id=track-section-song-1630231297,parentId=track-section-song]
							104 text Jimmy Cooks (feat. 21 Savage) ￼
							105 button (disabled) Drake
							106 button More
						107 container Description: One Dance (feat. Wizkid & Kyla), ID: Music.shelfItem.TrackLockup[id=track-section-song-1440843496,parentId=track-section-song]
							108 text One Dance (feat. Wizkid & Kyla)
							109 button (disabled) Drake
							110 button More
						111 container Description: Fair Trade (feat. Travis Scott), ID: Music.shelfItem.TrackLockup[id=track-section-song-1584281493,parentId=track-section-song]
							112 text Fair Trade (feat. Travis Scott) ￼
							113 button (disabled) Drake
							114 button More
						115 container Description: GREECE (feat. Drake), ID: Music.shelfItem.TrackLockup[id=track-section-song-1523923826,parentId=track-section-song]
							116 text GREECE (feat. Drake) ￼
							117 button (disabled) DJ Khaled
							118 button More
						119 container Description: Passionfruit, ID: Music.shelfItem.TrackLockup[id=track-section-song-1440891494,parentId=track-section-song]
							120 text Passionfruit ￼
							121 button (disabled) Drake
							122 button More
						123 container Description: God's Plan, ID: Music.shelfItem.TrackLockup[id=track-section-song-1418213269,parentId=track-section-song]
							124 text God's Plan ￼
							125 button (disabled) Drake
							126 button More
						127 container Description: POPSTAR (feat. Drake), ID: Music.shelfItem.TrackLockup[id=track-section-song-1523923824,parentId=track-section-song]
							128 text POPSTAR (feat. Drake) ￼
							129 button (disabled) DJ Khaled
							130 button More
						131 button (disabled) Previous Page
						132 button (disabled) Next Page
					133 section (disabled) Playlists
						134 button Description: Playlists, ID: Music.shelf.header[parentId=square-section-playlist,itemCount=75,itemKind=squareLockup]
							135 button (disabled) Playlists
							136 image See More
						137 container Description: Drake Essentials, ID: Music.shelfItem.SquareLockup[id=square-section-playlist-pl.b8afd0ec852542f785a5f7a4a9a80d6a,parentId=square-section-playlist]
							138 button (disabled) Drake Essentials
						139 container Description: Drake: Chill, ID: Music.shelfItem.SquareLockup[id=square-section-playlist-pl.e5bc0180234b40639b5fb6aeb3c6ff68,parentId=square-section-playlist]
							140 button (disabled) Drake: Chill
						141 container Description: Drake: Deep Cuts, ID: Music.shelfItem.SquareLockup[id=square-section-playlist-pl.9c2961c0bd034974a954fa788f7eac3b,parentId=square-section-playlist]
							142 button (disabled) Drake: Deep Cuts
						143 container Description: Drake: Love Songs, ID: Music.shelfItem.SquareLockup[id=square-section-playlist-pl.34a41c73937e4994a8a5cdc243e917cc,parentId=square-section-playlist]
							144 button (disabled) Drake: Love Songs
						145 container Description: Drake’s The Anita Max Win Tour Set List, ID: Music.shelfItem.SquareLockup[id=square-section-playlist-pl.9e6d4fbb09f34aeeb4024414e8c3f4b0,parentId=square-section-playlist]
							146 button (disabled) Drake’s The Anita Max Win Tour Set List
						147 button (disabled) Previous Page
						148 button (disabled) Next Page
					149 section (disabled) Radio Shows
						150 button Description: Radio Shows, ID: Music.shelf.header[parentId=square-section-radio_show,itemCount=2,itemKind=squareLockup]
						151 container Description: OVO SOUND RADIO, ID: Music.shelfItem.SquareLockup[id=square-section-radio_show-993270827,parentId=square-section-radio_show]
							152 button (disabled) OVO SOUND RADIO
						153 container Description: FREEBANDZ RADIO, ID: Music.shelfItem.SquareLockup[id=square-section-radio_show-1203923193,parentId=square-section-radio_show]
							154 button (disabled) FREEBANDZ RADIO
						155 button (disabled) Previous Page
						156 button (disabled) Next Page
					157 section (disabled) Radio Episodes
						158 button Description: Radio Episodes, ID: Music.shelf.header[parentId=square-section-radio_episode,itemCount=50,itemKind=squareLockup]
							159 button (disabled) Radio Episodes
							160 image See More
						161 container Description: Drake, ID: Music.shelfItem.SquareLockup[id=square-section-radio_episode-ra.1691953746,parentId=square-section-radio_episode]
							162 image Description: Explicit, Value: ￼
						163 container Description: Drake, ID: Music.shelfItem.SquareLockup[id=square-section-radio_episode-ra.1555122562,parentId=square-section-radio_episode]
						164 container Description: Drake, ID: Music.shelfItem.SquareLockup[id=square-section-radio_episode-ra.1149151498,parentId=square-section-radio_episode]
						165 container Description: Drake, ID: Music.shelfItem.SquareLockup[id=square-section-radio_episode-ra.1716594328,parentId=square-section-radio_episode]
						166 container Description: Drake, ID: Music.shelfItem.SquareLockup[id=square-section-radio_episode-ra.1759413581,parentId=square-section-radio_episode]
						167 button (disabled) Previous Page
						168 button (disabled) Next Page
				169 scroll bar (settable, float) 0.2875918051797449
					170 value indicator (settable, float) 0.2875918051797449
					171 increment arrow button
					172 decrement arrow button
					173 increment page button
					174 decrement page button
			175 container Description: Mini Player, ID: Music.miniPlayer.contentView[viewState=mini,isPlaying=false]
				176 button Description: do not shuffle, ID: Music.miniPlayer.shuffleButton
				177 button Description: Previous, ID: Music.miniPlayer.leadingTransportControl
				178 button Description: Play, ID: Music.miniPlayer.playbackTransportControl
				179 button Description: Next, ID: Music.miniPlayer.trailingTransportControl
				180 button Description: do not repeat, ID: Music.miniPlayer.repeatButton
				181 container Music.miniPlayer.metadataRegion[state=populated]
					182 button Description: Mini Player Artwork, ID: Music.miniPlayer.artwork
					183 text Value: Saiyaara (From "Saiyaara"), ID: Music.miniPlayer.title
					184 button Description: Favourite, ID: Music.miniPlayer.favoriteButton
					185 button Description: More, ID: Music.miniPlayer.contextMenu
					186 slider (settable, float) Description: Track Position, Value: 0.008391891891891892, Details: Not Playing, ID: Music.miniPlayer.playbackSlider
					187 text 0:03
					188 button ‎−6:07
				189 button Description: Lyrics, ID: Music.miniPlayer.lyricsButton
				190 button Description: playing next, ID: Music.miniPlayer.queueButton
				191 button Description: Volume, ID: Music.miniPlayer.volumeButton
		192 toolbar
			193 search text field (settable, string) Value: Drake, Placeholder: Apple Music
				194 button Search
				195 button cancel
			196 UIA.Music.Search.Scope
				197 radio button Description: Apple Music, Value: 1
				198 radio button Description: Library, Value: 0
		199 close button
		200 full screen button Help: this button also has an action to zoom the window, Secondary Actions: zoom the window
		201 minimise button
	202 menu bar
		203 Music
		204 File
		205 Edit
		206 Song
		207 View
		208 Controls
		209 Account
		210 Window
		211 Help

The focused UI element is 193 search text field.
```

## 9. `drag`

**Input**

```json
{"app":"com.apple.Music","from_x":266,"from_y":382,"to_x":300,"to_y":382}
```

**Raw Output**

```text
App=com.apple.Music (pid 40054)
Window: "Music", App: Music.
	0 standard window Music, Secondary Actions: Raise
		1 split group
			2 scroll area ID: sidebarScroller, Secondary Actions: Scroll Up, Scroll Down
				3 outline Description: Sidebar, ID: outline
					4 row (selected) Search
					5 row (selectable) Home
					6 row (selectable) Description: Grid view, Value: New
					7 row (selectable) Description: radio, Value: Radio
					8 row (selectable) Library
					9 row (selectable) Description: clock, Value: Recently Added
					10 row (selectable) Description: artist, Value: Artists
					11 row (selectable) Albums
					12 row (selectable) Description: song, Value: Songs
					13 row (selectable) Description: music video, Value: Music Videos
					14 row (selectable) Description: selfie, Value: Made for You
					15 row (selectable, expanded) Value: Playlists, Secondary Actions: Collapse
					16 row (selectable) All Playlists
					17 row (selectable) Description: favourite, Value: Favourite Songs
					18 row (selectable) Romeo Is Dead
					19 row (selectable) 21 Savage Essentials
					20 row (selectable) Anuv Jain Essentials
					21 row (selectable) AP Dhillon Essentials
					22 row (selectable) Ariana Grande Essentials
					23 row (selectable) ATG's playlist
					24 row (selectable) Blue
					25 row (selectable) Blues Guitar Giants On Alligator Records
					26 row (selectable) Description: playlist, Value: Bollywood Hits
					27 row (selectable) Description: playlist, Value: Brent Faiyaz Essentials
					28 row (selectable) Description: playlist, Value: Chill
					29 row (selectable) Description: playlist, Value: Chris Brown Essentials
					30 row (selectable) Diljit Dosanjh Essentials
					31 row (selectable) Drake Essentials
					32 row (selectable) Ed Sheeran Essentials
					33 row (selectable) Ed Sheeran’s Mathematics Tour Set List
					34 row (selectable) Eminem Essentials
					35 row (selectable) Future Essentials
					36 row (selectable) hindi nostalgia
					37 row (selectable) In My Room
					38 row (selectable) Description: playlist, Value: JAŸ-Z Essentials
					39 row (selectable) Description: playlist, Value: Joji Essentials
					40 row (selectable) Lil Wayne Essentials
					41 row (selectable) Logic Essentials
					42 row (selectable) Metro Boomin Essentials
					43 row (selectable) My Shazam Tracks
					44 row (selectable) Nas Essentials
					45 row (selectable) Party All Night with Bollywood
					46 row (selectable) Post Malone Essentials
					47 row (selectable) Description: playlist, Value: R&B Now
					48 row (selectable) Replay 2023
					49 row (selectable) Replay 2024
					50 row (selectable) Description: playlist, Value: RnB for the Soul
					51 row (selectable) Romeo Is High
					52 row (selectable) Sigma
					53 row (selectable) The Travel Playlist (Bollywood)
					54 row (selectable) Description: playlist, Value: The Weeknd Essentials
					55 row (selectable) The Weeknd: Fitness+ Spotlight
					56 row (selectable) Travis Scott Essentials
					57 row (selectable) Ultimate Bollywood
					58 row (selectable) Description: playlist, Value: Your Essentials
				59 scroll bar (settable, float) 0
					60 value indicator (settable, float) 0
					61 increment arrow button
					62 decrement arrow button
					63 increment page button
					64 decrement page button
			65 button Description: Affan The Great, ID: Music.accountButton
			66 splitter (disabled, settable, float) 216
			67 scroll area Secondary Actions: Scroll Up, Scroll Down
				68 collection
					69 section (disabled)
						70 container Description: MIA (feat. Drake) - Single, ID: Music.shelfItem.SquareLockup[id=square-section-album-1662168785,parentId=square-section-album]
							71 button (disabled) MIA (feat. Drake) - Single
							72 button (disabled) Bad Bunny
						73 container Description: POPSTAR (feat. Drake) - Single, ID: Music.shelfItem.SquareLockup[id=square-section-album-1523923474,parentId=square-section-album]
							74 button (disabled) POPSTAR (feat. Drake) - Single
							75 button (disabled) DJ Khaled
							76 image Description: Explicit, Value: ￼
						77 container Description: Honestly, Nevermind, ID: Music.shelfItem.SquareLockup[id=square-section-album-1630230040,parentId=square-section-album]
							78 button (disabled) Honestly, Nevermind
							79 button (disabled) Drake
							80 image Description: Explicit, Value: ￼
						81 container Description: GREECE (feat. Drake) - Single, ID: Music.shelfItem.SquareLockup[id=square-section-album-1523923810,parentId=square-section-album]
							82 button (disabled) GREECE (feat. Drake) - Single
							83 button (disabled) DJ Khaled
							84 image Description: Explicit, Value: ￼
						85 container Description: Toosie Slide - Single, ID: Music.shelfItem.SquareLockup[id=square-section-album-1505943426,parentId=square-section-album]
							86 button (disabled) Toosie Slide - Single
							87 button (disabled) Drake
							88 image Description: Explicit, Value: ￼
						89 button (disabled) Previous Page
						90 button (disabled) Next Page
					91 section (disabled) Songs
						92 button Description: Songs, ID: Music.shelf.header[parentId=track-section-song,itemCount=50,itemKind=trackLockup]
							93 button (disabled) Songs
							94 image See More
						95 container Description: NOKIA, ID: Music.shelfItem.TrackLockup[id=track-section-song-1796127375,parentId=track-section-song]
							96 text NOKIA ￼
							97 button (disabled) Drake
							98 button More
						99 container Description: MIA (feat. Drake), ID: Music.shelfItem.TrackLockup[id=track-section-song-1662168786,parentId=track-section-song]
							100 text MIA (feat. Drake)
							101 button (disabled) Bad Bunny
							102 button More
						103 container Description: Jimmy Cooks (feat. 21 Savage), ID: Music.shelfItem.TrackLockup[id=track-section-song-1630231297,parentId=track-section-song]
							104 text Jimmy Cooks (feat. 21 Savage) ￼
							105 button (disabled) Drake
							106 button More
						107 container Description: One Dance (feat. Wizkid & Kyla), ID: Music.shelfItem.TrackLockup[id=track-section-song-1440843496,parentId=track-section-song]
							108 text One Dance (feat. Wizkid & Kyla)
							109 button (disabled) Drake
							110 button More
						111 container Description: Fair Trade (feat. Travis Scott), ID: Music.shelfItem.TrackLockup[id=track-section-song-1584281493,parentId=track-section-song]
							112 text Fair Trade (feat. Travis Scott) ￼
							113 button (disabled) Drake
							114 button More
						115 container Description: GREECE (feat. Drake), ID: Music.shelfItem.TrackLockup[id=track-section-song-1523923826,parentId=track-section-song]
							116 text GREECE (feat. Drake) ￼
							117 button (disabled) DJ Khaled
							118 button More
						119 container Description: Passionfruit, ID: Music.shelfItem.TrackLockup[id=track-section-song-1440891494,parentId=track-section-song]
							120 text Passionfruit ￼
							121 button (disabled) Drake
							122 button More
						123 container Description: God's Plan, ID: Music.shelfItem.TrackLockup[id=track-section-song-1418213269,parentId=track-section-song]
							124 text God's Plan ￼
							125 button (disabled) Drake
							126 button More
						127 container Description: POPSTAR (feat. Drake), ID: Music.shelfItem.TrackLockup[id=track-section-song-1523923824,parentId=track-section-song]
							128 text POPSTAR (feat. Drake) ￼
							129 button (disabled) DJ Khaled
							130 button More
						131 button (disabled) Previous Page
						132 button (disabled) Next Page
					133 section (disabled) Playlists
						134 button Description: Playlists, ID: Music.shelf.header[parentId=square-section-playlist,itemCount=75,itemKind=squareLockup]
							135 button (disabled) Playlists
							136 image See More
						137 container Description: Drake Essentials, ID: Music.shelfItem.SquareLockup[id=square-section-playlist-pl.b8afd0ec852542f785a5f7a4a9a80d6a,parentId=square-section-playlist]
							138 button (disabled) Drake Essentials
						139 container Description: Drake: Chill, ID: Music.shelfItem.SquareLockup[id=square-section-playlist-pl.e5bc0180234b40639b5fb6aeb3c6ff68,parentId=square-section-playlist]
							140 button (disabled) Drake: Chill
						141 container Description: Drake: Deep Cuts, ID: Music.shelfItem.SquareLockup[id=square-section-playlist-pl.9c2961c0bd034974a954fa788f7eac3b,parentId=square-section-playlist]
							142 button (disabled) Drake: Deep Cuts
						143 container Description: Drake: Love Songs, ID: Music.shelfItem.SquareLockup[id=square-section-playlist-pl.34a41c73937e4994a8a5cdc243e917cc,parentId=square-section-playlist]
							144 button (disabled) Drake: Love Songs
						145 container Description: Drake’s The Anita Max Win Tour Set List, ID: Music.shelfItem.SquareLockup[id=square-section-playlist-pl.9e6d4fbb09f34aeeb4024414e8c3f4b0,parentId=square-section-playlist]
							146 button (disabled) Drake’s The Anita Max Win Tour Set List
						147 button (disabled) Previous Page
						148 button (disabled) Next Page
					149 section (disabled) Radio Shows
						150 button Description: Radio Shows, ID: Music.shelf.header[parentId=square-section-radio_show,itemCount=2,itemKind=squareLockup]
						151 container Description: OVO SOUND RADIO, ID: Music.shelfItem.SquareLockup[id=square-section-radio_show-993270827,parentId=square-section-radio_show]
							152 button (disabled) OVO SOUND RADIO
						153 container Description: FREEBANDZ RADIO, ID: Music.shelfItem.SquareLockup[id=square-section-radio_show-1203923193,parentId=square-section-radio_show]
							154 button (disabled) FREEBANDZ RADIO
						155 button (disabled) Previous Page
						156 button (disabled) Next Page
					157 section (disabled) Radio Episodes
						158 button Description: Radio Episodes, ID: Music.shelf.header[parentId=square-section-radio_episode,itemCount=50,itemKind=squareLockup]
							159 button (disabled) Radio Episodes
							160 image See More
						161 container Description: Drake, ID: Music.shelfItem.SquareLockup[id=square-section-radio_episode-ra.1691953746,parentId=square-section-radio_episode]
							162 image Description: Explicit, Value: ￼
						163 container Description: Drake, ID: Music.shelfItem.SquareLockup[id=square-section-radio_episode-ra.1555122562,parentId=square-section-radio_episode]
						164 container Description: Drake, ID: Music.shelfItem.SquareLockup[id=square-section-radio_episode-ra.1149151498,parentId=square-section-radio_episode]
						165 container Description: Drake, ID: Music.shelfItem.SquareLockup[id=square-section-radio_episode-ra.1716594328,parentId=square-section-radio_episode]
						166 container Description: Drake, ID: Music.shelfItem.SquareLockup[id=square-section-radio_episode-ra.1759413581,parentId=square-section-radio_episode]
						167 button (disabled) Previous Page
						168 button (disabled) Next Page
				169 scroll bar (settable, float) 0.2894941634241245
					170 value indicator (settable, float) 0.2894941634241245
					171 increment arrow button
					172 decrement arrow button
					173 increment page button
					174 decrement page button
			175 container Description: Mini Player, ID: Music.miniPlayer.contentView[viewState=mini,isPlaying=false]
				176 button Description: do not shuffle, ID: Music.miniPlayer.shuffleButton
				177 button Description: Previous, ID: Music.miniPlayer.leadingTransportControl
				178 button Description: Play, ID: Music.miniPlayer.playbackTransportControl
				179 button Description: Next, ID: Music.miniPlayer.trailingTransportControl
				180 button Description: do not repeat, ID: Music.miniPlayer.repeatButton
				181 container Music.miniPlayer.metadataRegion[state=populated]
					182 button Description: Mini Player Artwork, ID: Music.miniPlayer.artwork
					183 text Value: Saiyaara (From "Saiyaara"), ID: Music.miniPlayer.title
					184 button Description: Favourite, ID: Music.miniPlayer.favoriteButton
					185 button Description: More, ID: Music.miniPlayer.contextMenu
					186 slider (settable, float) Description: Track Position, Value: 0.008391891891891892, Details: Not Playing, ID: Music.miniPlayer.playbackSlider
				187 button Description: Lyrics, ID: Music.miniPlayer.lyricsButton
				188 button Description: playing next, ID: Music.miniPlayer.queueButton
				189 button Description: Volume, ID: Music.miniPlayer.volumeButton
		190 toolbar
			191 search text field (settable, string) Value: Drake, Placeholder: Apple Music
				192 button Search
				193 button cancel
			194 UIA.Music.Search.Scope
				195 radio button Description: Apple Music, Value: 1
				196 radio button Description: Library, Value: 0
		197 close button
		198 full screen button Help: this button also has an action to zoom the window, Secondary Actions: zoom the window
		199 minimise button
	200 menu bar
		201 Music
		202 File
		203 Edit
		204 Song
		205 View
		206 Controls
		207 Account
		208 Window
		209 Help

The focused UI element is 191 search text field.
```
