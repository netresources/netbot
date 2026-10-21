# Windows setup dialogs (PowerShell + WinForms)

The final, dish-first setup flow for the native PowerShell installer, styled to match the dashboard. On screen the equipment is "dish" and "router", with no product or company names.
Reference code: `windows-dialog-sample.ps1` shows styling only and wires nothing up (`-Screen DishMonitoring|RouterEntry|AddonFound|NoAddon|RouterPassword|Success|Error`).
Mockups (HTML rendered to PNG, because PowerShell is not available on the design box), in flow order: `dialogs/windows/1-dish-monitoring.png`, `2-router-entry.png`, `3a-addon-found.png`, `3b-no-addon.png`, `4-router-password.png`, `5-success.png`, `6-error.png`. All seven: `dialogs/windows-flow-sheet.png`.

## Tokens
| Token | Hex | `System.Drawing.Color` | Use |
|---|---|---|---|
| Bg | `#06080B` | `FromArgb(6, 8, 11)` | text-field fill, primary button text, title bar (dark mode) |
| Panel | `#0C1117` | `FromArgb(12, 17, 23)` | window body, secondary button fill |
| Raised | `#121922` | `FromArgb(18, 25, 34)` | button strip, secondary hover |
| Hairline | `#263241` | `FromArgb(38, 50, 65)` | 1 px rule above the strip |
| Control | `#56667A` | `FromArgb(86, 102, 122)` | borders of fields, secondary buttons and chips |
| Text | `#F2F5F8` | `FromArgb(242, 245, 248)` | heading, field text, list items |
| Text 2 | `#A7B2C0` | `FromArgb(167, 178, 192)` | body |
| Text 3 | `#7B8796` | `FromArgb(123, 135, 150)` | field labels, hints, placeholders |
| Accent | `#3DF26F` | `FromArgb(61, 242, 111)` | top stripe and kicker (screens 1–4), primary button, focused field border |
| Accent hover | `#8AF7A4` | `FromArgb(138, 247, 164)` | primary hover |
| OK | `#37A484` | `FromArgb(55, 164, 132)` | success stripe and kicker only |
| Alert | `#FF5C5C` | `FromArgb(255, 92, 92)` | error stripe, kicker and inline error messages only |

Contrast (WCAG 2.x): Text/Panel 17.3:1, Text 2/Panel 8.8:1, Text 3/Panel 5.2:1, Text 3/Bg (placeholder) 5.5:1, Accent/Panel 8.4:1, OK/Panel 6.1:1, Alert/Panel 6.3:1, button text Bg/Accent 8.9:1 (hover 11.0:1), field text Text/Bg 18.3:1. The Control border is 3.2:1 on Panel, which passes the 3:1 rule for non-text elements.
**Screens 1 and 3b deliberately use the Accent, not amber or red**, including the dish-not-reachable-yet variant and the no-add-on result. They are information, not warnings.

## Fonts (Windows system fonts, nothing to ship or license)
| Role | Font | pt → px at 96 DPI |
|---|---|---|
| Heading | Segoe UI Semibold | 12 → 16 |
| Body, text fields | Segoe UI | 9.75 → 13 |
| Hints, inline messages | Segoe UI | 9 → 12 |
| Buttons | Segoe UI Semibold | 9.75 → 13 |
| Kicker, field labels, chips (UPPERCASE) | Consolas Bold | 8.25 → 11 |
| Password field | Consolas | 11.25 → 15 |
| List items, log path | Consolas | 9 → 12 |

## Frame (all screens)
- `FormBorderStyle = FixedDialog`, no minimize or maximize, `StartPosition = CenterScreen`, title **"NetBot"**, `AutoScaleMode = Dpi`. All px values are at 96 DPI and scale with display settings.
- `ClientSize` width **460**. Padding 24 px on the left and right. Content width **412**.
- Top stripe: 0, 0, 460, 3. Kicker: 24, 27, 412, 16. Heading: 24, 47, 412, 26. Body starts at y 77.
- Button strip: the bottom **72 px**, Raised fill, 1 px Hairline at the top. Buttons are 32 px high at strip y 21, min 96 px wide (text + 32), 8 px apart, right-aligned with a 24 px right margin, flat with a 1 px border. The primary button is on the right.
- Optional dark title bar: `DwmSetWindowAttribute(hwnd, 20, 1)` on Windows 10 20H1+ and 11. It is ignored elsewhere.

## Screen 1: Dish monitoring is on (ClientSize 460 x 245)
| Element | x, y, w, h | Content |
|---|---|---|
| Stripe / kicker | as frame | Accent · `● DISH MONITORING` |
| Heading | 24, 47, 412, 26 | **Dish monitoring is on** |
| Body | 24, 77, 412, 76 | Found: "NetBot found your dish at {dish address}. Every 5 minutes it checks the dish's status, outages, obstruction, latency, throughput and alerts, plus ping, latency, packet loss and speed tests on your connection." · Not reachable yet: "NetBot can't reach your dish at {dish address} right now. Dish monitoring is still on, and NetBot will keep trying every 5 minutes." |
| Buttons | strip | **Continue** (primary, Enter **and** Esc) |

## Screen 2: Router entry (ClientSize 460 x 305)
| Element | x, y, w, h | Content |
|---|---|---|
| Stripe / kicker | as frame | Accent · `● ROUTER · OPTIONAL` |
| Heading | 24, 47, 412, 26 | **What router do you have?** |
| Body | 24, 77, 412, 57 | "Optional. If NetBot has an add-on for your router, it can also show router stats, such as connected devices and Wi-Fi signal. The make and model are usually on a label on the router." |
| Label / field | 24, 146, 198, 16 / 24, 166, 198, 28 | `MAKE` / TextBox, cue banner "Brand on the label", `AccessibleName` "Router make", focused on open |
| Label / field | 238, 146, 198, 16 / 238, 166, 198, 28 | `MODEL` / TextBox, cue "For example X100", `AccessibleName` "Router model" |
| Hint | 24, 200, 412, 18 | "Not sure? Dish and network monitoring work without it." |
| Buttons | strip | **I'm not sure** (secondary, Esc) · **Continue** (primary, Enter) |
Continue with both fields empty acts like "I'm not sure". Next is 3a or 3b.

## Screen 3a: Router add-on found (ClientSize 460 x 226)
| Element | x, y, w, h | Content |
|---|---|---|
| Stripe / kicker | as frame | Accent · `● ROUTER ADD-ON FOUND` |
| Heading | 24, 47, 412, 26 | **There is an add-on for your router** |
| Body | 24, 77, 412, 57 | "NetBot can add router stats for your {Make} {Model}: WAN connection, connected devices and Wi-Fi signal. You can turn it on now or later." |
| Buttons | strip | **Not now** (secondary, Esc) · **Turn On** (primary, Enter) |
Turn On goes to screen 4 if the add-on needs a password, or to 5 if not. Not now goes to 5 with the router add-on off.

## Screen 3b: No add-on (ClientSize 460 x 288)
| Element | x, y, w, h | Content |
|---|---|---|
| Stripe / kicker | as frame | **Accent** · `● DISH + NETWORK MONITORING` |
| Heading | 24, 47, 412, 26 | **NetBot will use dish and network monitoring** |
| Body | 24, 77, 412, 38 | Variant A: "There is no add-on for this router yet, and that's fine. NetBot will still watch:" · Variant B (I'm not sure): "No problem. NetBot will still watch:" |
| List (2 x 2) | 24/236, 123/147, 200, 18 | Consolas 9, Text, accent square mark: "Dish status and alerts", "Outages and obstruction", "Ping, latency and loss", "Speed tests" |
| Footnote | 24, 177, 412, 19 | "You can add a router add-on later by running setup again." |
| Buttons | strip | **Continue** (primary, Enter **and** Esc) |

## Screen 4: Router password, optional (ClientSize 460 x 343). Show it only if the add-on needs a password.
| Element | x, y, w, h | Content |
|---|---|---|
| Stripe / kicker | as frame | Accent · `● ROUTER ADD-ON · OPTIONAL` |
| Heading | 24, 47, 412, 26 | **Router password (optional)** |
| Body | 24, 77, 412, 76 | "The router add-on can read more router stats with your router's admin password." ⏎⏎ "It is saved only on this computer, in Windows Credential Manager." |
| Label | 24, 165, 412, 16 | `ROUTER ADMIN PASSWORD` |
| Password | 24, 185, 412, 28 | `UseSystemPasswordChar = $true` (system bullets), `ShortcutsEnabled = $false`, `AccessibleName` "Router admin password", focused on open |
| Hint | 24, 217, 412, 34 | "Characters are hidden as you type. Skip if you prefer. The add-on then shows only what the router shares without a password." |
| Buttons | strip | **Skip** (secondary, Esc) · **Save** (primary, Enter) |
Inline messages replace the hint, in Alert color with a ◆ prefix: "Type the password, or choose Skip." · "NetBot could not save the password (error {code}). Nothing was stored. Try again, or choose Skip." · "The router did not accept that password. Try again, or choose Skip."
The password is never echoed, logged, put on a command line or written to a file. Clear the TextBox after storing it. "Windows Credential Manager" assumes that is the store the engineers choose, so reword it if not.

## Screen 5: Success (ClientSize 460 x 271)
| Element | x, y, w, h | Content |
|---|---|---|
| Stripe / kicker | as frame | OK · `● OK · INSTALLED` |
| Heading | 24, 47, 412, 26 | **NetBot is installed** |
| Body | 24, 77, 412, 38 | "NetBot checks your dish and connection every 5 minutes. Bookmark the dashboard so you can find it later." |
| Chips | from 24, 127, height 22, 8 px gaps, wrap at 436 | `● DISH · ON`, `● NETWORK CHECKS · ON`, `● ROUTER ADD-ON · ON` or `○ ROUTER ADD-ON · OFF`. On = Accent border + Text. Off = Control border + Text 2 |
| Buttons | strip | **Close** (secondary, Esc) · **Open Dashboard** (primary, Enter) |

## Screen 6: Error (ClientSize 460 x 228)
| Element | x, y, w, h | Content |
|---|---|---|
| Stripe / kicker | as frame | Alert · `◆ ALERT · INSTALL FAILED` (no line art) |
| Heading | 24, 47, 412, 26 | **NetBot could not finish installing** |
| Body | 24, 77, 412, 19 | "NetBot stopped before it finished. Details are in:" |
| Log path | 24, 108, 412, 28 | read-only TextBox, Consolas 9, the expanded `%USERPROFILE%\NetBot\install.log`, `AccessibleName` "Install log location" |
| Buttons | strip | **Show Log** (secondary, opens it in Notepad) · **OK** (primary, Enter **and** Esc) |
Specific causes (replace the body, and add 19 px per extra line): "PowerShell 5.1 or newer is needed. Update Windows, then run setup again." · "Python 3.9 or newer is needed. Install it, then run setup again." · "NetBot could not download a required component. Check the internet connection, then run setup again." · "NetBot needs permission to create a scheduled task. Run setup again and choose Yes when Windows asks."

## Accessibility
- **Not color alone:** each screen has a kicker word (DISH MONITORING / ROUTER / ROUTER ADD-ON FOUND / DISH + NETWORK MONITORING / OK / ALERT), a shape (● or ◆) and a heading, as well as the stripe color.
- **Keyboard:** Enter = primary (`AcceptButton`). Esc = the secondary action, or the only or OK button, as listed per screen. Handle Esc with `KeyPreview` + `KeyDown` (as in the sample), or set `CancelButton`. Tab order follows reading order: fields first, then secondary, then primary. Flat buttons must still show a focus cue: a 2 px Text focus rectangle (owner-drawn) or `ShowFocusCues`.
- **Screen readers:** real `Label` controls, `AccessibleName` on every field, and placeholders that are never the only label.
- **Scaling:** `AutoScaleMode = Dpi`. Test at 100/125/150%. Labels are sized for one extra wrapped line.
- **High contrast:** when `SystemInformation.HighContrast` is true, use system colors instead of these tokens.
