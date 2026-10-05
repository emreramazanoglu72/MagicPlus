# Changelog

All notable changes to MagicPlus are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.3.0] — 2026-08-25

### Added

- **An assistant in the dock.** A button on the bar opens a chat that can act on this Mac: find
  files, open applications and folders, take notes, list and focus windows, set the volume, read the
  battery and disk, and search the clipboard history. It picks its own tools and says what it is
  doing as it goes — "searching files for *invoice* — 3 results" — because an agent that disappears
  for eight seconds and comes back with an answer is indistinguishable from one that made the answer
  up.

  Three providers, chosen in Settings → AI: Claude, OpenAI, and Cloudflare Workers AI. The model is a
  dropdown, and it is asked of the provider rather than baked in — a list compiled into this app is a
  list that is wrong by the next release, and a picker offering something the account cannot call is
  worse than a text field. Before a key is set, or if the listing call fails, a short built-in list
  stands in and says so. "Custom…" is there for a model newer than either. Keys live in the login
  keychain, one per provider, and never in this app's settings file — a plist is something any
  process can read and every backup carries. A "test the connection" button spends one real round
  trip so a bad key is found in Settings rather than mid-question.

  Deliberately not a shell. The assistant has a closed list of ten narrow, typed tools, every one of
  them read-only or reversible; there is no `run_command`, and there will not be. "What can the AI do
  to my machine" is a question that has to be answerable by reading one list. Nothing here is new
  capability either — files come from Spotlight, notes go to the shelf that already existed, windows
  through the window lister — so the assistant is a language interface over what the app already
  does rather than a second implementation of it. Off until a key is set: a button whose only answer
  is "no API key is set" is not a button.

  Bounded on purpose: six rounds of tool use per message, and a message that hits the limit says so
  rather than going quiet. Each round is a paid call, and a model stuck in a loop should run out of
  leash rather than out of somebody's credit.

- **Answers arrive as they are written** rather than all at once when they are finished. Both APIs
  stream the same way — a line of `data:` per fragment — and both break a reply into pieces that mean
  nothing alone: text a few characters at a time, and a tool call as a name in one event with its
  arguments split across a dozen more, none of them valid JSON by itself. The reassembly is a state
  machine kept away from the network and tested against recorded events, because a dropped fragment
  is a tool called with half its arguments and nothing about that looks like an error.

  A provider that cannot stream still works: the whole answer arrives as one fragment, and nothing
  above that line has to know which kind it is talking to.

  Worth knowing, and measured rather than assumed: how much streaming is *felt* depends on the model.
  Against `llama-4-scout` the first words arrive in half a second; against `glm-4.7-flash`, which
  reasons before it answers, in nineteen — it spends the wait thinking and then streams the whole
  answer in one. The feature is not what decides this.

- **The assistant can be spoken to and can speak back.** A microphone in the input row dictates into
  the field — and only into the field: recognition mis-hears, and an assistant that acts on the
  machine should not be able to act on a mis-heard word. Recognition is asked to run on this Mac
  whenever macOS can, and the button's tooltip says which is happening, because that is the one fact
  somebody dictating a private note would want and the one nobody thinks to look up.

  Answers can be read aloud, offline and without any permission at all. Code blocks are not read out
  — a shell command spoken character by character is noise — and the voice follows the *answer's*
  language rather than the app's, since the assistant answers in whatever language it was asked in.

- **The chat stays open when you click away.** It closed on losing focus, like the start menu it was
  modelled on — but a menu and a conversation are different things: you could not read the answer and
  do the thing you asked about at the same time, which is most of what it is for. A pin in the header
  keeps it, and pinned it can be dragged wherever it is wanted.

- **The chat window can be resized**, and remembers the size. Any answer with code in it was
  unreadable in a fixed four-hundred-point panel.

- **Answers with code in them are drawn as code.** SwiftUI's `Text` understands inline markdown and
  nothing about block structure, so a fenced block arrived as a paragraph with three backticks in it
  — and an assistant is asked for commands more than for anything else. Code blocks now have their
  own surface, the language they were tagged with, horizontal scrolling and a copy button; whole
  answers have one too, on hover. A fence left unclosed by a truncated answer closes at the end,
  because half a code block is still code.

- **A failed message can be tried again** without retyping it, from the last thing actually said —
  the half-finished exchange that failed is not context. And the up arrow on an empty field brings
  the last message back to be edited, the way a terminal does.

- **The chat says what the conversation has cost.** Every provider reports token usage and this app
  was throwing it away; a measured comparison of seven models found a tenfold spread between them, so
  somebody spending their own money should be able to see the number.

- **Each step can be opened to show exactly what the tool was sent and what it returned.** This agent
  does things on somebody's machine, and "what did it actually pass to that tool" should be
  answerable by the person whose machine it is rather than only by reading the source.

- The header names the model that answered, because two models give very different answers to the
  same question and knowing which one this was is half of judging the answer.

- **The assistant can read files**, which is the first thing anybody asks about one and the thing
  it could not do: text and code directly, PDFs as their text, pictures and screenshots through text
  recognition. One tool rather than three — a measured comparison of seven models showed small ones
  failing at *choosing* between tools long before they failed at using one — so the file decides.

  Reading is the one thing here that takes something private and sends it to somebody else's
  computer, so there is a policy and it is a separate, tested function rather than a condition buried
  in the reading: inside the home folder only, judged after the path is standardized so a `..` cannot
  climb out of it, and never `.ssh`, `.aws`, `.env`, keychains or anything else that holds
  credentials. Long files are cut and say they were cut, because a model that believes it read the
  end will answer questions about the end.

- **The assistant is told what is going on before it asks.** The date and time, the application in
  front and its window title, what is playing, the battery — about forty tokens, read from what the
  dock already polls rather than fetched again, and it removes a whole paid round from the most
  common questions. The clipboard is deliberately not among them: searching it is something somebody
  asks for, and this travels with every message whether it was wanted or not.

- **A strip on every display.** There was one panel, and a panel joined to every Space still only
  ever sits on one screen — so a second monitor had no dock at all. One per display now, added and
  removed as displays arrive and go. They share a style, so the icons are sized to fit the narrowest
  screen rather than each strip overwriting the other's answer on every tick, and the menus that open
  out of an icon find their strip by where the pointer is rather than by being told.

- **The bar can hide itself until the pointer reaches the edge.** Off by default: a dock that is not
  there is a dock somebody has to remember exists. Parked, it slides off its own edge and leaves
  three points behind — and because the window stays whole, reaching for that sliver is already a
  hover on the strip. No mouse monitor, and nothing running at all when the setting is off. It holds
  no screen space while it hides, the same as an auto-hiding system Dock, and it will not park itself
  while its own menu or chat is standing open on it.

- **The assistant can be stopped.** While something is in flight the send button is a stop button,
  because that is where the hand already is. The provider call is a `URLSession` request and
  cancellation reaches it, so it is a real stop rather than an ignored answer — previously a slow
  model locked the chat for as long as it took and the only way out threw away the conversation.

- **Icons can be dragged along the bar to rearrange them**, and an application dragged in from the
  Finder pins itself where it lands. One gesture, one code path: what is being dragged says which it
  is, so nothing has to remember whether a drag started inside the dock — a piece of state that goes
  stale the moment a drag is cancelled.

- **A pinned folder opens into its contents** rather than into the Finder. Newest first, because a
  folder pinned to a dock is almost always somewhere things arrive. Read off the main thread and
  capped, so a folder with thousands of entries opens at once rather than completely; "Open in
  Finder" is there for the rest.

- **Files can be dropped on the assistant.** They wait as chips over the field with the placeholder
  asking what to do with them, because a dropped file is half a request and the half that matters is
  still being typed. The paths travel with the message; the transcript shows only what was typed.

- **A Show Desktop sliver at the very end of the bar**, where Windows has put it for fifteen years:
  one click clears the screen, another puts it back. Deliberately not an icon among icons — it is a
  nine-point strip running the bar's full height, flush against the corner, so it can be hit without
  aiming.

  It hides the applications rather than posting F11. macOS's own Show Desktop is a keyboard shortcut
  the user is free to change or switch off, and a button that silently does nothing is worse than no
  button; hiding needs no permission at all and can be tested. What it hid is remembered rather than
  re-derived, because "everything hidden" is not "everything this hid" — something hidden by hand
  before the click stays hidden after the next one.

- **Files can be dropped on the dock.** Onto an application to open them with it, onto a pinned
  folder to move them there, onto the bin to put them in it — the icon grows and outlines itself in
  the accent colour while a drag is over it, so the drop says where it is going before it lands.
  Nothing is deleted: the bin means the bin, and what goes there can be taken back out. A tile with
  nothing to do with files refuses the drop rather than accepting it and quietly doing nothing.

- **A ring on the bar fills while something is downloading**, and is not there when nothing is. The
  queue already knew its own progress; this is that number where a glance finds it.

- **A start menu** behind the first button in the bar: a search field, everything installed in a
  grid, and the five commands that end a session — sleep, lock, log out, restart, shut down. Arrow
  keys and the pointer move the same selection, so Return always opens what is highlighted. The
  application list is the one `AppLauncher` already built for the window switcher.

- **A volume slider** behind the speaker, which is what a speaker icon promises. It used to open the
  app's whole popover.

- **A menu on the bar itself.** Right-clicking the strip rather than an icon on it offers where it
  sits, its settings, and the way back to the system Dock — the three things wanted when the answer
  is "not here".

- **Richer menus on the icons**: that application's open windows by title first, because that is
  what a right-click on a running app is usually reaching for, then Show, New Window, Show in
  Finder and Quit.

- **A dock of the app's own.** macOS exposes nothing about the real Dock's appearance — no colour,
  no opacity, no radius, and the old `no-glass` sort of trick has been gone for years — so the only
  way to change how a dock looks is to draw one. Surface (glass, solid colour, or none), tint,
  opacity, edge, icon size, spacing, margin and alignment.

  Its contents come from the real Dock's own preferences, so it opens with the icons already
  arranged the way they were, labels included. Nothing is written back: rearranging the Dock is the
  Dock's business.

  While it is up the system Dock is hidden, and what the Dock's settings were beforehand is written
  down first and restored when ours goes away — including after a crash, which is checked at every
  launch. A Mac left without a Dock and no obvious way to get one back is not an acceptable failure
  mode for a menu bar app.

### Changed

- **The dock's two unreachable shapes are gone**, and with them five hundred and fifty lines of view
  and a picker's worth of settings. A row of magnifying icons and a sidebar listing windows were both
  still in the code after the themes that offered them were deleted — nothing in the app could select
  either, so they described something nobody could see. The style value lost `layout`, `magnifies`,
  `magnifiedSize`, `cornerRadius`, `tileCornerRadius` and `sidebarWidth` with them.

- **The bar has been redesigned.** It was a flat run of small controls on a near-opaque black band.
  It is now dark glass — the system's own blur under a tint thin enough that the wallpaper still
  comes through — with bigger icons, room between them, and one hairline of light along the edge
  that faces the screen. Nothing else is drawn: no panels behind the groups, no outlines, no
  dividers. What separates one group from the next is distance. A version with all of those frames
  was built first and thrown away; they made it look like a settings window lying on its side.

- **The strip takes its colour from whatever you are working in.** The dominant colour of the front
  application's icon lights the hairline and breathes into the edge, and marks that app's icon with a
  capsule in its own colour. Read by binning the icon's pixels by hue rather than averaging them,
  which returns mud; an icon with no colour in it leaves the bar neutral instead of inventing a hue
  for it.

- **Playback shows a cover, a progress line and an equaliser.** The track's name says what is on; a
  line creeping along underneath says how much is left, which is the thing people actually glance
  down for. The equaliser is honest about being decorative — it is not driven by the audio — and
  holds still when Reduce Motion is on.

- **Icons grow under the pointer** instead of lighting up a grey rectangle behind themselves, which
  is both what the Dock has always done and the only treatment that does not need a frame drawn
  around it.

- **The icons sit in the middle of the bar by default.** A strip that spans the whole screen with its
  icons crowded into the left corner is mostly empty bar, and the emptiness is the first thing anyone
  sees. Where they sit was already a setting — and the bar was ignoring it, so the picker in Settings
  moved nothing. It works now.

- **The bar draws its own contents in its own appearance.** It paints a dark surface, so it used to
  get dark grey labels on dark grey glass in Light Mode. What decides it is the colour the bar is
  actually painted, not what the rest of the desktop is doing.

- Styles saved by an earlier build are carried onto the new look once, rather than keeping the old
  one for ever. Only the fields that describe how the strip is drawn are taken fresh — where it sits,
  how big its icons are and whether it holds screen space back are decisions somebody made, and they
  survive.

- **The applications window has been redesigned** in the same language as the strip it opens out of:
  the same dark glass, no dividers, and the two bands of chrome told apart from the grid by being a
  shade darker rather than by a line drawn across the panel. Bigger tiles six across, a search field
  in a capsule with a clear button, and section headings with counts — applications that are already
  open first, then everything else. The selected tile wears that application's own colour, the same
  colour the bar uses to mark what is in front. The session buttons light up under the pointer, and
  Shut Down turns red: it is the one button there that cannot be taken back.

- **The arrow keys move through that grid as a grid.** Down went to the next tile, which through a
  hundred and fifty applications six across is not navigation; it goes to the next row now. Left and
  right move a tile at a time, but only while the search field is empty — the moment there is
  something to type through, they belong to the caret.

- Application icons are kept once read. `LaunchableApp.icon` goes to disk through `NSWorkspace` every
  time it is read, which is fine for the five rows the window switcher shows and not fine for a grid
  of everything installed asking for all of them on every pass.

- Dock settings no longer offers a corner radius or a magnification size. The bar reads neither, and
  a control that moves nothing is worse than one that is missing. "Light up the icon under the
  pointer" is now "Grow the icon under the pointer", which is what it does.

### Fixed

- **The release script bumped the version and shipped the old one anyway.** `agvtool` is the wrong
  tool for this project — the version lives in a build setting and Xcode generates the plist key,
  while agvtool goes looking for plists to patch. It announced success, wrote nothing that lasted,
  failed with `Cannot find ".../YES"`, and because its output went to `/dev/null` the release carried
  on: a notarized 1.3.0, correctly signed and stapled, labelled 1.2.0 and staged over the previous
  release's package. The version is set in the project file now and the built app is checked against
  what was asked for before anything is staged.

- **The build number was not bumped with the version, which made the release undeliverable.** Sparkle
  compares build numbers, so 1.3.0 carrying 1.2.0's build number is an update offered to nobody —
  and `generate_appcast` keys its cached metadata on that number, so the new item came out carrying
  the old release's title: a feed announcing 1.2.0 and handing over 1.3.0. Everything about it looked
  right. The script bumps the build number too, and refuses to stage anything whose number is not
  higher than the newest already in the feed.

- **The Turkish translation check only worked by accident.** It depended on build artefacts a
  previous universal build had left in `DerivedData`; deleting that folder broke it, which is the
  definition of a hidden dependency rather than a build step. It builds what it needs first. (The
  `ONLY_ACTIVE_ARCH=YES` it passed to avoid this was never honoured by the localization export.)

- **A bare file name was refused for being outside the home folder.** Asked to read `notes.txt`, the
  path was resolved against whatever directory the process was started in — so the refusal was a true
  sentence about a path nobody meant. A relative path means the home folder now. Found the same way
  as the tilde before it: by asking the assistant a real question rather than by reading the check.

- **A file path beginning with `~` was refused for being somewhere it was not.** Models write
  `~/Documents/notes.txt` because people do, and `URL(fileURLWithPath:)` reads the tilde as an
  ordinary folder name — so a file plainly in the home folder came back "outside the user's home
  folder". Found by asking the assistant a real question about a real file rather than by reasoning
  about the check.

- **Catching `SIGTERM` had made the app unkillable while the main thread was busy.** Ignoring the
  signal removes the only thing guaranteed to end the process, and the replacement was handled on the
  main queue — which walks the Accessibility tree on a timer and can be occupied for hundreds of
  milliseconds. A `pkill` landing in one of those windows would be ignored and then never acted on.
  Found reviewing the fix that introduced it, one commit later. It runs on a queue of its own now,
  restores the Dock through `CFPreferences` and a subprocess rather than anything belonging to the
  main actor, and exits after two seconds regardless.

- **Settings understated what the assistant sends.** "File names and paths, not file contents" was
  true of the file search and false of the whole: searching the clipboard history sends the matching
  entries, which is whatever had been copied — passwords included. The note now says which tools send
  text and what that means.

- **A failed keychain write still reported success.** `KeychainStore.save` returned nothing and
  ignored both status codes, so Settings said "saved in your keychain" over a key that was never
  stored. It reports, and Settings says so when it fails.

- **The assistant's conversation grew without bound.** Every round re-sent the whole transcript plus
  about fourteen hundred tokens of tool schemas, so a long conversation cost quadratically and
  eventually overran the model's context — surfacing as a provider error rather than anything
  actionable. A window of recent turns travels now, widened whenever it would otherwise separate a
  tool call from its result: every provider rejects a result whose call it cannot see.

- **The strip's whole view graph was invalidated every one and a half seconds for nothing.** Four
  observed properties — the front application's name, icon, identifier and window title — were
  assigned on every tick whether or not they had changed, and an observable assigned its own value
  dirties the graph exactly as hard as a real change: twenty-six icons, their colours and the layout,
  all re-evaluated. The island's playback, battery and volume did the same. Assigned only on a real
  change now: SwiftUI's graph work fell to a third of what it was and the app at rest went from about
  a fifth of a core to a seventh.

- **Every tick walked the Accessibility tree twice** for the same list of windows: once to find the
  front window's title, once to keep windows out of the strip. One sweep now, read by both.

- **An icon's right-click menu never listed that application's windows.** The list was only gathered
  for the sidebar layout, and the sidebar was removed — so it was always empty, and the titles at the
  top of the menu, which are the first thing a right-click on a running app is reaching for, silently
  went away with it.

- **Killing the app left the Mac with no Dock at all.** It hides the system Dock and parks it on
  another edge to do its job, and `applicationWillTerminate` does not run for a signal — so `pkill`,
  or anything else sending `SIGTERM`, left the Dock parked and hidden with no visible way back. That
  happened, here, and had to be undone by hand. The signal is caught now and the Dock is put back.
  `SIGKILL` still cannot be caught by anything, so the check at the next launch stays the backstop.

- **Two docks were on screen in Mission Control.** macOS draws the real Dock over Mission Control,
  Launchpad and App Exposé whatever its settings say — parked and hidden included — so ours made a
  second one. It steps aside for all three now. Detecting them took measuring: swiping into Mission
  Control does not change which application is frontmost, which is the obvious signal and not a
  signal at all. What changes is the Dock's own windows.

- **Every conversation using a tool failed on its second round with Cloudflare Workers AI.** The
  assistant's own turn carries `content: null` when it is nothing but tool calls, which OpenAI
  accepts and Workers AI rejects with a 400 — so the tool ran, its result went back, and the reply
  to it was an error. It carries an empty string now, which both take. Found by making one real call
  rather than by reasoning about the documentation.

- **The start menu and the volume slider stayed open when the dock was clicked.** They closed on
  losing key status, which covers a click in another application and misses the one that matters: the
  bar is a non-activating panel, so clicking it never takes key status away from anything. A click
  anywhere outside now closes them — in this application or another — while the button that opened
  them is left alone, so it still toggles rather than closing and reopening in one gesture.

- **The strip vanished and came back late when swiping between Spaces.** It only asked whether
  something was full screen when applications were switched, and a three-finger swipe is not an
  application switch — so the answer waited for the next tick, a second and a half away, in both
  directions. It is asked on every Space change now. It also stopped ordering the window out of the
  window server and back in: a window joined to every Space has to be re-added to all of them each
  time it returns, and doing that during a swipe is what made it arrive after the animation had
  finished. It fades instead, and stops taking clicks while it is invisible.

- **A full-screen window was being shrunk by the height of the strip, once every tick, for as long
  as you stayed on that Space.** Keeping windows out of the reserved strip is right for windows this
  app places; a full-screen window is the system's, and resizing one is a fight with macOS over the
  Space that macOS wins noisily. They are left alone now — recognised by covering their whole display,
  which a zoomed window does not, since it stops at the menu bar.

- Asking Accessibility whether a window is full screen is given a fifth of a second to answer rather
  than the default six. That question is asked in the middle of a Space animation, and nothing about
  a dock is worth holding a swipe up for.

- **The app froze on launch.** Every icon's right-click menu asks whether that application opens at
  login, and answering it meant an `osascript` subprocess and the better part of a second waiting on
  System Events. SwiftUI builds those menus while it evaluates the strip's body, so with a dock full
  of icons that was two dozen blocking subprocesses inside a single layout pass — a sample of the
  hang was two and a half seconds of one `NSHostingView.layout()`, stuck in `read()`. The login-item
  list is now read in the background, once, and cached; the menu answers from the last reading and
  never blocks. Adding or removing one still runs the script, off the main thread, and throws the
  cache away afterwards so the checkmark stays honest.

- **The strip asked a browser what it was playing on the main thread, every one and a half seconds.**
  That is a few hundred milliseconds the whole interface spends frozen, over and over. It is read off
  the main thread now — the way the notch has always read it — and at a fifth of the rate, because
  the notch is asking the same question on its own schedule and a track title does not change twice a
  second. Pressing play or skip still reads it immediately.

- **The playback equaliser was re-laying out the entire strip sixty times a second.** Its bars
  animated their height, and an animated height is an animated *layout*: two dozen icons, the
  spacers and the clock were all measured again on every frame, for three bars four points tall.
  They keep a fixed height and are scaled now, which is a transform the render server does on its
  own.

- **The dock showed only the applications that were running.** The ones deliberately kept in the
  dock — the whole point of a dock — were the ones it left out. Pinned applications, pinned folders
  and running ones now all appear, in the order the Dock itself lists them, with a gap rather than a
  line between the groups.

- **The bar came up 1632 points wide on an 1800-point screen**, 48 points off the bottom, and stayed
  there. It measured itself against `visibleFrame`, which means "whatever the Dock has left over" —
  the wrong reference for something that replaces the Dock, and a moving target read at the worst
  moment: while the real Dock was still sliding to the edge it gets parked on. Nothing posts a second
  screen-parameter change once it settles, so that first wrong answer was the last one. It is
  measured against the display's own frame now.

- A test of the download offer's clock waited a fixed few hundred milliseconds past its deadline,
  which passes on an idle Mac and fails on a busy one — it did, twice in an afternoon. It waits for
  the condition now, and still fails if the clock never runs out.

- **A crowded dock shrank its icons before closing its gaps.** Showing every pinned application put
  twenty-six tiles on the strip, and it answered by taking the icons from 32 points to 23 while eight
  points of slack still sat in the spacing. The gaps go first now, down to a floor, and only then do
  the icons.

- **The bin ended up in the middle of the bar**, dragging the volume and the clock to the far edge
  with it. A `Color` with only its height fixed is infinitely wide, and the empty space where a
  non-running tile's indicator would go was stretching the whole right-hand group across the screen.

- **The strip's height was worked out in two places** — once for the window and once for the view —
  which is the same shape of mistake that once sent the dock off the edge of the screen. There is one
  answer now and both read it.

- **The system Dock kept appearing from under our bar.** Hiding it is not enough: a hidden Dock
  still slides out when the pointer reaches the edge it lives on, and `autohide-delay` does not hold
  it back — so every trip to our own bar along the bottom brought it out. It is now also parked on
  the edge ours is not on, and its previous position is saved and restored with the rest. Verified
  from a clean baseline: nothing written before, nothing left behind after.

- **Window previews came back.** Hovering an app with two windows open used to show both, because
  the system Dock was there to hover; replacing it took that away. The previews now hang off our own
  icons, and the panel is told which edge they are on rather than asking the Dock — which is parked
  somewhere else entirely.

- **Windows sitting under the bar.** Subtracting the strip from this app's own placement was half an
  answer: other apps know nothing about it and open over it. A window found in the strip is now
  moved out of it — conservatively, so a window a few points over the line is left alone rather than
  made to twitch, and shrunk only when it is too big to fit by moving.

  One limit worth stating: a window that is zoomed or in full screen re-asserts its own frame, and
  the Accessibility call reports success without changing anything. Those stay where they are.




- **The dock froze the app and then crashed it**, and the reason was mine: hover was reported out
  of SwiftUI to a controller that rebuilt the view and repositioned the window — several times a
  second, from inside AppKit's own layout pass. AppKit answers that with an uncaught exception
  (`-[NSWindow _postWindowNeedsUpdateConstraints]`, straight from the crash report) rather than a
  warning, and the rebuild loop is what froze it in between. Magnification now never leaves the
  view: it is `@State`, the view is built once and follows an observable model, and the window is
  only ever moved from a scheduled task, outside any layout pass.

- Icons were read from disk with `NSWorkspace.icon(forFile:)` on every frame of the magnification
  animation — two dozen filesystem reads per frame. Cached.

- **The dock ran off the screen**: 2159pt of dock on an 1800pt display, and 1523pt down a 1049pt
  edge. The icons now shrink until it fits, the way the real Dock does when it gets crowded —
  measured with the same function that sizes the window rather than solved on paper, because the
  room magnification needs depends on the very size being solved for, and one pass of arithmetic
  gets that wrong in the direction that still overflows.

- That fit was being computed at launch, when `NSScreen.main` is still nil, so it silently skipped
  and never ran again. It happens during layout now, which is the only moment there is a screen to
  measure against.

- `NSHostingView` pushes its own idea of the right size into its window and wins over the frame the
  controller set, which is how a dock clamped to 1008pt appeared 1523pt tall. The view now takes
  exactly the window's size, from the same arithmetic, so there is nothing to disagree about.

## [1.2.0] — 2026-08-23

### Added

- **The Dock settings Apple ships and never shows.** A new *Dock Settings* module, prompted by
  looking at what [DockFix](https://www.dockfix.app) sells: half of that app is a custom Dock
  replacement, which is a different product, and the other half is revealing preferences
  `Dock.app` already reads. This is that half — plus window previews and a file shelf, which this
  app already had.

  Nine of them, none of which appears in System Settings: the half-second wait before a hidden
  Dock slides out, the slide's own duration, showing only running apps, the attention bounce, the
  launch bounce, dimming apps hidden with ⌘H, single-app mode, scroll-up-for-windows, and Mission
  Control's grouping. Plus the third minimise effect — *Suck* — which the Dock can draw and Apple's
  interface does not offer. Plus separator tiles, which have never had an interface anywhere.

  Three decisions worth writing down. **The Dock's own domain is the only copy of the truth**, so a
  value someone changed in Terminal is the value the pane shows; a mirror in this app's preferences
  would eventually disagree with the Dock, and the Dock would win. **Off removes the key** rather
  than writing a false-ish value, so the Dock falls back to its own default and "restore" means
  removing exactly what was added — a test proves `tilesize` and `orientation`, which this page
  never offers, survive a restore untouched. And **switching the module off gives the Dock back**,
  because a module that is off must not still be changing the Mac.

  Settings System Settings already exposes are deliberately absent: undoing a choice someone made
  in Apple's own interface is not this app's business.

  Verified on the real Dock, not only against a test domain: a separator added to a 22-tile Dock,
  the Dock restarted by launchd, the separator removed, and the list identical to how it was found.
  The tests themselves write to a domain of their own, because a suite that rearranges the Dock of
  whoever runs it is not a suite anyone should run twice.


- **HLS streams are fetched by the app itself.** A `.m3u8` manifest is not a file — it is a list of
  a few hundred small ones — so there was nothing for the downloader to resume and the whole job
  went to `ffmpeg`. That put an install step in front of exactly the sites people most often want
  something from, and it was the last thing in the app that asked for a tool.

  The manifest is now read here: the rendition closest to the chosen quality is picked (never
  rounding *up* — asking for 1080 must not fetch 2160 and four times the bytes), segments are
  fetched four at a time and appended strictly in playlist order, and the result is rewritten as an
  MP4 using AVFoundation, which reads concatenated MPEG-TS and fragmented MP4 — verified against
  Apple's own sample stream, not assumed. Progress is estimated from what the segments have
  averaged so far, because a manifest never says how big the stream is.

  How far it got is recorded beside the file being written, so quitting the app costs the segment
  in flight rather than the hour already spent. A live stream and an encrypted manifest are each
  refused with a sentence saying which, since neither has an end to download to.

  Two things the tests caught that would otherwise have shipped: a server that ignores `Range` and
  answers 200 with the whole file — appending that where a slice was asked for gives a stream of
  plausible length and entirely wrong contents, so the slice is now taken locally — and
  AVFoundation refusing to open the assembled stream at all, because it decides what a file holds
  from its extension and the file was called `.part`.

- **Report an Issue**, in the menu and in Settings. The app has no analytics and is not getting
  any, and the cost of that is that a failure nobody can describe is a failure that never gets
  fixed. This writes the report instead: build, macOS, Mac model, which modules are on, what was
  granted, and the errors this session recorded — in an email the user reads before sending. The
  system version is assembled rather than borrowed, because `operatingSystemVersionString` is
  localised and a report that says "Sürüm 26.5.1" to one reader cannot be compared with one that
  says "Version 26.5.1".

### Changed

- `LSApplicationCategoryType` is set. It had been empty, which Xcode warns about on every release
  build and which leaves Finder's Get Info panel with a blank field.

## [1.1.0] — 2026-08-23

### Added

- **Modules.** MagicPlus is a dozen small utilities sharing a menu bar item, and most people want
  two or three of them — but only five could be switched off, each from whichever tab it happened
  to live in, and the rest ran whether you used them or not. Settings now has a *Modules* tab
  listing every part of the app with what it does and what it costs.

  A module is a first-class thing rather than a checkbox: it knows **which global shortcuts belong
  to it**, so one that is off holds none of them rather than taking a system-wide combination away
  from every other app on behalf of something you turned off. Switching one off releases what it
  was holding — samplers stop, observers come off, status items go back — and its tabs disappear
  from the popover and the island, because a tab with nothing behind it is worse than no tab.

  `AppEnvironment.applyModules()` is the single authority on all of that, and it is idempotent. The
  five switches that already existed keep their own preference keys, so a choice made before any of
  this is still the one being read: there is no second copy of that truth to drift out of step.

- **Download queue**: copy a link and the island offers it with a *Get* badge; the prompt asks
  for the name, the folder and — on a media page — the quality before a byte is written.
  Transfers resume from the size of their own `.part` file, so pausing, quitting and coming
  back tomorrow continues them instead of starting over, and a server that ignores the range
  is detected rather than producing a corrupt file. The queue runs as many at once as you
  choose, reports size, speed and time remaining, never overwrites a file you already have,
  and puts a small progress ring on the resting island. Links dropped onto the island and a
  new *Download Link on Clipboard* menu item go through the same prompt.
- **The extension speaks Turkish.** Its context-menu item, notifications and window come from
  `_locales`, and the right-click item now appears on the page itself as well as on links, video,
  audio and images — on a video page the page is the useful thing to hand over, and it goes
  straight to the media prompt.
- **Browser extension**: a Chromium extension (`Extension/chromium`) that hands downloads to
  MagicPlus with the cookies, referer and user agent the browser would have sent — the context
  that decides whether a signed or session-gated link works at all outside the browser. The
  browser's own transfer is paused, offered, and only cancelled once MagicPlus accepts it, so a
  failed hand-off never costs a download. It reaches the app over a listener bound to 127.0.0.1
  in the range 27717–27726; every endpoint but `/ping` needs a token, and a token is only issued
  after the user approves a dialog naming the extension — from an origin only a browser extension
  can mint, which is what closes the cross-site attack on a local port. Paired browsers are
  listed in Settings and can be disconnected at any time.
- **Media a page is playing**, found by watching the player's own requests rather than by
  extracting anything: the site's JavaScript has already signed those URLs, so repeating one
  inherits the signature, the `n` transform and any proof-of-origin token for free — no helper,
  no cryptography, and nothing to keep chasing. The island offers whichever formats turned up,
  and `ffmpeg` joins picture and sound where a site serves them apart. The trade is inherent to
  the approach: only a format the page actually asked for can be offered.
- **Browser tab watching**: with Automation permission, media pages and file links in the
  front tab are offered as they appear. Only the address of the tab is read. A refused
  permission is reported in Settings with a button to the right System Settings pane, because
  a feature that appears not to work is the one failure a user cannot diagnose.
- **Media pages**: no site extractors are bundled and none are downloaded. With `yt-dlp`
  installed, a media page is offered with a quality picker and runs in the same queue, with the
  same progress and pause behaviour as any other download. Without it, the prompt says so and
  offers to install it in a Terminal window the user can watch. Every quality asks for separate
  video and audio streams where `ffmpeg` can join them, because the single-file formats YouTube
  used to serve now answer 403 on most videos; with no `ffmpeg` present the prompt says that
  before the download rather than after. An optional, off-by-default setting lets the helper
  read cookies from a browser you are signed into, which is what gets past a site that blocks a
  stream partway through or hides a page behind an age check — and a blocked download names the
  setting that would have fixed it rather than repeating the helper's error.
- **Menu bar manager**: the bar is cut into visible, hidden and always-hidden sections by two
  status items of its own. ⌘-drag an item to the left of the divider and it stays out of
  sight until the chevron, `⌃⌥H`, or a hover over the bar brings it back — with a choice of
  when it folds away again, and a wait for any menu opened from it to close first.
- **Hidden items strip**: hidden items can be shown in a panel under the menu bar instead of
  being folded back into it, for bars with no room left. Clicking one clicks the real item.
- **Menu bar item search** (`⌃⌥S`): a Spotlight-style panel over every item in the bar,
  hidden ones included, that clicks the one you pick.
- **Menu bar appearance**: an optional solid or gradient tint over the bar, with a bottom
  border, that gets out of the way in full screen.
- **Menu bar item spacing**: the system-wide gap between items and the padding around their
  highlight, adjustable and resettable from Settings → Menu Bar.
- **Temperatures and fans**: every sensor the Mac reports, read from the SMC and grouped into
  CPU, GPU, battery, ambient and storage, with fan speeds against their own limits and an
  optional CPU temperature in the menu bar. Discovered from the machine rather than from a
  model table, and read-only.
- **Battery condition**: full-charge capacity against design capacity, cycle count and battery
  temperature.
- **Battery charge limit**: hold the battery at 50–100% instead of letting it fill, through a
  privileged helper that is installed on demand, accepts a fixed list of requests from this
  app alone, and restores normal charging when MagicPlus quits, crashes or goes quiet for 30
  seconds. Needs a signed build; every other feature works without it.

- **The island asks rather than hints.** A found link no longer arrives as a capsule with a
  badge: the island grows downward into a card carrying the title, the site, the size or the
  quality, and the number of formats found, with *Download* / *Choose quality*, *Paste a link*
  and a dismiss button. It holds for sixteen seconds, stops that clock while the pointer is over
  it, waits its turn if the panel is already open, and stays silent in presentation mode.
- **Type a link yourself**: detection guesses, and sometimes wrongly. The prompt now takes an
  address — from the card's *Paste a link*, the `+` in the downloads pane, or the menu bar item —
  probes it as you stop typing, and fills in the name, size and folder it works out.

- **Automatic updates that actually work.** The updater had been shipping inert: `SUPublicEDKey`
  existed only inside a comment, so Sparkle was never started and the *Check for Updates* item
  never appeared — 2.8 MB of framework doing nothing, and no way to reach anyone who had already
  installed the app. There is now a signing key, the app checks once a day, and `release.sh`
  generates the appcast itself instead of printing instructions for doing it by hand.
  It also refuses to finish if the feed comes out unsigned. `generate_appcast` omits the
  signature *silently*, with a success message, when the archived app carries no `SUPublicEDKey`
  to verify it with — a feed every install rejects, discovered only by a user whose update fails.
- **An About panel**, from the status item menu. Version, build and copyright, which the app had
  no way of telling anyone: the only place the version was read was the browser bridge's `/ping`
  reply. A bug report that cannot name a build cannot be answered.
- **Turkish permission dialogs.** There was no `InfoPlist.xcstrings` at all, so the sentences
  macOS shows when it asks for Automation, Calendar, Camera and audio capture could not be
  translated — a Turkish user was asked for the Camera in English, by the system, at the least
  reassuring possible moment.
- `Scripts/check-localization.sh`, which reports every string with no translation using Xcode's
  own export. The check this replaces counted keys present in the catalog and reported zero
  problems while **46 strings were still shipping in English**; SwiftUI's literals are never a
  call to anything, so nothing short of the compiler can find them. Now 0 of 563.

### Changed

- **Joined downloads no longer need anything installed.** A site that serves picture and sound
  apart is now two ordinary downloads — each resumable, each with exact progress and the
  browser's own headers — joined afterwards by the muxer macOS already carries. The external tool
  is a fallback for the two cases it is genuinely needed for: WebM, which AVFoundation will not
  write, and the per-track files some sites misdeclare.
- **A found link arrives as a capsule, not a card.** Something unfolding over whatever someone is
  doing is an interruption for a download they may not want, so the island states the find in a
  capsule — what it is, the quality or size, and a chevron. Pointing at it grows it into the full
  card and stops the clock; the pointer leaving shrinks it back. Clicking the capsule outright
  skips to the prompt, for anyone who aims and taps in one motion.
- **The playing tab is the one described, not the one in front.** With the extension connected,
  the browser reports which of its tabs is audible — something nothing outside a browser can see,
  and the reason a video went unnamed in the island the moment you switched tabs. Core Audio still
  decides *whether* a browser is playing, so a report cannot outlive the sound it describes;
  without the extension the front tab remains the best guess available.
- **The now-playing pane wears the cover.** The artwork is now both things it should be: sharp and
  small beside the title, and spread across the pane behind everything, blurred and darkened. A
  page has no cover art of its own but it has the still frame it would put on a link to itself,
  which is a far better answer than a grey music note over a running video. Fetched once per page
  rather than once per poll.
- **The prompt wears the page's own still frame.** A download prompt for a video that shows a grey
  icon says nothing about what is about to be downloaded; the frame says all of it. A YouTube
  address carries its own identifier so the thumbnail needs no request to find, and every other
  site is asked once for its `og:image` — the tag the whole web already fills in so links look
  right when shared. It sits behind the panel, blurred to a colour field, with the crisp frame
  where the icon was. Reduce Transparency turns it off.
- **A found link no longer waits sixteen seconds.** The card holds for three, and pointing at it
  stops the clock — so it only ever runs out on an offer being ignored.

- **Interruptions are waited out rather than failed.** A dropped connection, a sleeping Mac or a
  server having a bad minute are all things that resolve themselves, and a queue that gives up on
  them makes the user the retry mechanism. Transient failures are now told apart from answers — a
  404 is final, a lost connection is not — and picked up again on a backoff of 2, 6, 15, 40 and 90
  seconds. Sleep puts running transfers down deliberately so they come back as downloads to resume;
  waking, or the network returning, starts them immediately rather than sitting out the rest of a
  wait. Pressing the row goes now.
- **The queue lives in the menu bar too.** It was only ever in the island, so switching the notch
  panel off left no way to see, pause or retry a download. There is now a *Downloads* tab in the
  popover with the same controls.
- **Room is checked before starting**, not discovered on the last byte, and abandoned `.part` files
  in the download folder are swept up after a week — the folder is the user's, not a scratch space.

- **The notch panel was redesigned around a design system rather than a set of one-off
  layouts.** `NotchDesign.swift` now holds the island's whole vocabulary — a 4pt spacing grid,
  four text sizes, four surface fills, three ink levels, five radii and a semantic colour set
  — and every control in the island is built from it. What it replaced: sixteen different
  white opacities, nine font sizes and six corner radii scattered across the views.
- Every pane in the expanded panel is now the same height, so the panel no longer resizes —
  and moves the tab the pointer is aiming at — as you switch between them.
- All thirteen island activities render through one presentation: glyph, headline, detail
  line, optional meter or badge. Previously each carried its own bespoke layout.
- The pane switcher is a segmented rail with a sliding indicator and equal segments; the
  shelf's share and empty buttons sit in a fixed slot so the rail no longer shifts when they
  appear.
- The media pane leads with 68pt artwork, a reserved scrubber line, a filled white play
  button as the single primary action, and volume on its own row.
- The mixer pane and the island now share one slider and one set of controls instead of two
  that behaved slightly differently.
- The panel body lifts a fraction off pure black and takes a hairline edge, while the strip
  level with the notch stays pure black — the part that has to pass for hardware.
- Defined the app's `AccentColor` asset, which had been shipping empty.

- **Modules govern the whole app, not just its panels.** Switching one off now also removes its
  items from the status item menu, its tab from Settings, its rows from the shortcut recorder —
  and stops the app asking for permissions on its behalf. The onboarding list is built from what
  the switched-on modules actually need, so turning the notch off stops the app requesting the
  Camera; with nothing that needs granting, the screen says so instead of showing an empty pane.
- Menu separators are only drawn between items that exist. A switched-off module used to leave
  its separator behind, and two rules in a row read as a menu that failed to load.
- The window-rule pickers have labels for VoiceOver. They had `""`, which announces nothing.

### Fixed

- **A found link stayed on screen indefinitely.** The island is told about every mouse move on
  the screen, and each report that the pointer was elsewhere restarted the three-second clock — so
  a question nobody answered stood there for as long as the mouse kept moving, which is most of
  the time. The clock is now restarted on the way out only, not on every report that it is still
  out.
- **A stream already seen was recorded again on every chunk.** The extension built its identity key
  from the raw address, which carries the byte range, so one video would have filled the list with a
  copy of itself per request. Found by the new `node` checks over the sniffer's logic.
- **The other tabs became unclickable while a cover was showing.** The now-playing pane's
  background was a hit-testable layer, and vertical padding had pushed the pane past the fixed
  height every pane is meant to keep — so it overflowed onto the tab rail and swallowed the
  clicks meant for it. The padding is gone and the background takes no clicks at all: decoration
  that can intercept is decoration that will. `PaneHeightTests` now measures every pane through a
  hosting view and fails if one differs, which is the check that would have caught it.
- **"Nothing playing" over a running video.** Browsers were deliberately never asked, on the
  reasoning that a tab title says nothing about whether it is playing. That was true of the title
  alone — it is not true of the title paired with Core Audio's own account of which processes are
  producing output. The island now names the page and the site when sound is actually coming out
  of a browser, and reads a title only under that condition rather than while someone merely
  browses. Sound coming from a browser's renderer process counts as the browser, which is where
  it always comes from.
- The island's window is the full expanded size and almost entirely transparent, and it was being
  treated as interactive across all of it. That swallowed clicks meant for the menu bar, and it
  counted the pointer as resting on a card that was nowhere near it — which is why an offer never
  timed out. The pointer is now taken only where the island is actually drawn.
- `ffmpeg` was handed HTTP options for local files when joining two halves already on disk, which
  it refuses outright ("Option not found"). It is only given them for remote inputs now.
- AVFoundation chooses a parser from a file's extension, so the `.part` files were unreadable to
  it. The halves are hard-linked to names carrying their real extension before joining — no extra
  space, and the originals stay in place for a retry.

- A pasted address was never checked for being a page, so a YouTube link typed by hand
  downloaded the page's HTML. The prompt now works out what an address is: a file fills in its
  name and size, a media page switches to the media path with its quality picker, and a page with
  no helper installed says plainly that its source is what would be saved.
- A sniffed `application/x-mpegurl` playlist was read as an MP3 — "mpeg" is a substring of
  "mpegurl" — which labelled every HLS stream on the web as audio. Rows now name the track and
  the format, carry the size where it is known, and identical ones are numbered rather than left
  as four ways of choosing nothing.
- A page the helper knows now goes to the helper rather than to a picker built from watched
  requests. Watching only ever finds the stream the player fetched, and on YouTube increasingly
  not even that; the helper lists every format the site has.

- A universal release build produced two warnings from Core Audio property reads — a generic
  `T` written over with raw bytes. Constrained to `BitwiseCopyable`, which is the actual safety
  argument, rather than silenced. Debug builds never showed it.
- The keep-awake caption's Turkish had been left on an older revision of the English text, so
  the longest explanation in Settings was showing in English.

## [1.0] — 2026-08-15

First public release.

### Added

- **Window manager**: 11 placement commands with width cycling, drag-to-edge snapping with a
  target preview, per-app placement rules, saved workspace layouts, multi-display support and
  a configurable gap.
- **Notch panel**: a Dynamic Island style surface that idles at exactly the hardware notch
  size — file shelf, playback control, Calendar agenda with Join links, camera mirror,
  volume and screenshot activities, threshold alerts, and a strip fallback for displays
  without a notch.
- **Clipboard history**: text, files and images with a Spotlight-style keyboard-driven panel,
  paste-time transforms, pinning, and detection of sensitive content that is never recorded.
- **Window switcher**: alt-tab across every window of every app, doubling as a launcher.
- **Dock previews**: live window previews on Dock icon hover, with close and minimise.
- **System monitor**: CPU, memory, disk, network and top processes, with an optional menu bar
  readout and visibility-driven sampling.
- **Keep awake**: IOKit power assertions with an optional timer and a menu bar indicator.
- **Meeting and safety tools**: microphone and camera indicators, system-wide panic mute,
  presentation mode, on-device OCR capture, window rescue after display changes, a menu
  command palette, and quick notes.
- **Audio mixer**: per-app volume and mute over macOS process taps, plus external display
  brightness over DDC/CI.
- **Localization**: English and Turkish from a single String Catalog, with an in-app language
  picker.
- **Updates**: Sparkle, with a signed and notarized DMG produced by `Scripts/release.sh`.

[Unreleased]: https://github.com/emreramazanoglu72/MagicPlus/compare/v1.0...HEAD
[1.0]: https://github.com/emreramazanoglu72/MagicPlus/releases/tag/v1.0
