# FrameTwin

frame generation for mac games. kinda like lossless scaling but for mac

it watches ur game window and makes a fake frame between evry 2 real ones. so a game running at 60 fps shows up at 120 on a 120hz screen. it works on any game (crossover wine gptk native whatever) cuz it never touches the game itself

**its early.** expect smearing and bugs

## how it works

1. ScreenCaptureKit grabs just the game window
2. the gpu guesses how evry part of the picture moved between the last 2 frames (shrinks the frames and searches small then refines it bigger)
3. both frames get moved halfway along that motion and blended into the in between frame
4. a see thru window sits rite on top of the game and shows middle frame then real frame. clicks go thru it to the game

## u need

- macOS 14 or newer
- apple silicon (intel might work but prolly slow)
- a high refresh screen to get the most out of it. on 60hz it only helps games that run at 30
- screen recording permission

## build and run

```
git clone https://github.com/DoofusPoofus/FrameTwin.git
cd FrameTwin
swift build -c release
.build/release/FrameTwin
```

the first time macos asks for screen recording permission. allow it and then restart FrameTwin. if u start it from terminal the permission goes to terminal not FrameTwin

## use it

1. start ur game in windowed or borderless windowed mode
2. click the FrameTwin icon in the menu bar and pick the game window
3. the menu bar shows real fps → shown fps
4. pick the game again or hit stop to turn it off

best results when u cap the game at half ur refresh rate (60 on a 120hz screen) so the pacing stays even

## known problems

- fast moving stuff can get a smeary halo around it
- the edges of the screen can look weird when the camera turns
- about 1 frame of extra input lag. thats how all frame gen works
- HUD and text can wobble a bit

## selftest

checks the motion math with fake frames and saves pngs of the result

```
.build/release/FrameTwin --selftest ./selftest-output
```

## license

MIT. see LICENSE
