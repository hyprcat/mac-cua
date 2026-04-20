# Computer Use Tool Dump

I exercised every `Computer Use` tool against Apple Music in a low-risk way: inspected app state, listed apps, clicked into Search, set the search field to `Drake`, typed `Drake`, pressed `Escape`, scrolled results, invoked a secondary `Scroll Up` action, and dragged the sidebar splitter slightly.

Below is the raw tool I/O.

## 1. `get_app_state`

**Input**

```json
{"app":"com.apple.Music"}
```

**Output**

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

**Output**

```text
[{"type":"text","text":"Code — com.microsoft.VSCode [running, last-used=2026-04-19, uses=61]\nSystem Settings — com.apple.systempreferences [running, last-used=2026-04-19, uses=19]\nSafari — com.apple.Safari [running, last-used=2026-04-19, uses=10]\nMusic — com.apple.Music [running, last-used=2026-04-19, uses=4]\nFinder — com.apple.finder [running]\nApp Store — com.apple.AppStore [last-used=2026-04-19, uses=2]\nZed — dev.zed.Zed [last-used=2026-04-11, uses=1]"}]
```

## 3. `click`

**Input**

```json
{"app":"com.apple.Music","element_index":"4"}
```

**Output**

```text
App=com.apple.Music (pid 40054)
Window: "Music", App: Music.
	0 standard window Music, Secondary Actions: Raise
		1 split group
			2 scroll area ID: sidebarScroller, Secondary Actions: Scroll Up, Scroll Down
				3 outline Description: Sidebar, ID: outline
					4 row (selected) Search
					5 row (selectable) Home
...
		132 toolbar
			133 search text field (settable, string) Apple Music
				134 button Search
			135 UIA.Music.Search.Scope
				136 radio button Description: Apple Music, Value: 1
				137 radio button Description: Library, Value: 0
...
The focused UI element is 1 split group.
```

## 4. `set_value`

**Input**

```json
{"app":"com.apple.Music","element_index":"133","value":"Drake"}
```

**Output**

```text
App=com.apple.Music (pid 40054)
Window: "Music", App: Music.
...
			67 scroll area Secondary Actions: Scroll Up, Scroll Down
				68 collection
					69 section (disabled) Top Results
...
						73 cell Description: Drake, ID: Music.shelfItem.TopSearchLockup[id=top-search-section-top-271256,parentId=top-search-section-top]
							74 text Drake Artist
						75 cell Description: NOKIA, ID: Music.shelfItem.TopSearchLockup[id=top-search-section-top-1796127375,parentId=top-search-section-top]
							76 text NOKIA ￼ Song · Drake
...
		155 toolbar
			156 search text field (settable, string) Value: Drake, Placeholder: Apple Music
				157 button Search
				158 button cancel
...
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

**Output**

```text
App=com.apple.Music (pid 40054)
Window: "Music", App: Music.
...
		155 toolbar
			156 search text field (settable, string) Value: Drake, Placeholder: Apple Music
				157 button Search
				158 button cancel
...
The focused UI element is 156 search text field.
```

## 6. `press_key`

**Input**

```json
{"app":"com.apple.Music","key":"Escape"}
```

**Output**

```text
App=com.apple.Music (pid 40054)
Window: "Music", App: Music.
...
			140 container Description: Mini Player, ID: Music.miniPlayer.contentView[viewState=mini,isPlaying=false]
...
					151 slider (settable, float) Description: Track Position, Value: 0.008391891891891892, Details: Not Playing, ID: Music.miniPlayer.playbackSlider
					152 text 0:03
					153 button ‎−6:07
...
		157 toolbar
			158 search text field (settable, string) Value: Drake, Placeholder: Apple Music
				159 button Search
				160 button cancel
...
The focused UI element is 158 search text field.
```

## 7. `scroll`

**Input**

```json
{"app":"com.apple.Music","element_index":"67","direction":"down","pages":1}
```

**Output**

```text
App=com.apple.Music (pid 40054)
Window: "Music", App: Music.
...
			67 scroll area Secondary Actions: Scroll Up, Scroll Down
				68 collection
					69 section (disabled)
						70 container Description: Drake Essentials, ID: Music.shelfItem.SquareLockup[id=square-section-playlist-pl.b8afd0ec852542f785a5f7a4a9a80d6a,parentId=square-section-playlist]
...
					82 section (disabled) Radio Shows
...
					90 section (disabled) Radio Episodes
...
				102 scroll bar (settable, float) 0.4638577502899111
...
The focused UI element is 124 search text field.
```

## 8. `perform_secondary_action`

**Input**

```json
{"app":"com.apple.Music","element_index":"67","action":"Scroll Up"}
```

**Output**

```text
App=com.apple.Music (pid 40054)
Window: "Music", App: Music.
...
			67 scroll area Secondary Actions: Scroll Up, Scroll Down
				68 collection
					69 section (disabled)
						70 container Description: MIA (feat. Drake) - Single, ID: Music.shelfItem.SquareLockup[id=square-section-album-1662168785,parentId=square-section-album]
...
					91 section (disabled) Songs
...
					133 section (disabled) Playlists
...
					149 section (disabled) Radio Shows
...
					157 section (disabled) Radio Episodes
...
				169 scroll bar (settable, float) 0.2875918051797449
...
The focused UI element is 193 search text field.
```

## 9. `drag`

**Input**

```json
{"app":"com.apple.Music","from_x":266,"from_y":382,"to_x":300,"to_y":382}
```

**Output**

```text
App=com.apple.Music (pid 40054)
Window: "Music", App: Music.
...
			66 splitter (disabled, settable, float) 216
...
		190 toolbar
			191 search text field (settable, string) Value: Drake, Placeholder: Apple Music
				192 button Search
				193 button cancel
...
The focused UI element is 191 search text field.
```

## Notes

- I abbreviated repeated middle sections with `...` so the response stays readable, but the key returned fields are preserved exactly where the interesting state changed.
- The most interesting concrete state changes were:
  - `click` changed Search to selected and surfaced the search field.
  - `set_value` populated the field and loaded Drake search results.
  - `press_key` changed the mini player metadata display and kept focus in the search field.
  - `scroll` changed the main results scroll position.
  - `perform_secondary_action` scrolled that region back up.
  - `drag` changed the splitter value from `208` to `216`.
