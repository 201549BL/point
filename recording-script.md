# Point: recording script

Record one continuous take of about 60 seconds. Go slowly, and pause for about 2 seconds after each step. I'll cut out the pauses and speed things up when I edit.

## Setup (once)
- Default Point settings: the blue annotation color, backdrop **off**, and **Desktop wallpaper** selected as the background.
- A clean desktop with a nice wallpaper. Turn on Do Not Disturb, hide desktop icons, and quit any apps you don't want in the shot.
- Open one window to screenshot, roughly in the middle of the screen. It needs:
  - something to point at (a button or a typo)
  - an email address (to blur)
  - a key, token or number (to redact)

  Open the fake demo page, `demo/index.html`, in your browser (`open demo/index.html`). It has all three: the clipped **Save changes** button, the email address, and the API key. All its data is fake.
- Open the chat demo, `demo/chat.html`, in a second window and place it partly behind the billing page. This sets up the backdrop step, which hides neighboring windows, and step 9. Reload the chat before each take to reset it.
- Optional: System Settings → Displays → choose a larger text size, so the UI reads better in the video.

## Record
Use **⌘⇧5 → Record Entire Screen**, and turn on "Show Mouse Clicks" under Options.

| # | Action | Then pause |
|---|---|---|
| 1 | Three-finger double-click, then drag a selection around the window. | 2s |
| 2 | Press **G**: the backdrop turns on. | 2s |
| 3 | Press **A**, then drag an arrow to the thing you're pointing at. | 1s |
| 4 | Double-click the arrow and type a short caption, e.g. `Button is cut off`. Press **Return**. | 2s |
| 5 | Press **B** and drag over the email address. | 2s |
| 6 | Press **R** and drag over the key or token. | 2s |
| 7 | Optional: press **⌘Z** and then **⌘⇧Z** (undo, redo). | 1s |
| 8 | Press **Return**. Wait for "Copied to clipboard". | 2s |
| 9 | Click the chat window. Press **⌘V**, type a short message (e.g. `Save button is clipped on Billing`), and press **Return**. Jonas replies "Good catch, will fix 👍" after about 3 seconds. | 4s |

If a step goes wrong, just do it again. I'll pick the best attempt.

## Send me
- The `.mov` file. Drop it in this folder or give me its path.
- If you used a different shortcut or caption, tell me which, so I can match the overlays.
