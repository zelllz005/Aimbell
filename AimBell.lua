--[[
=====================================================================
  AIMBELL  [beta]   |   Roblox Luau   |   client-side   |   mobile first
=====================================================================
  RUN:   executor -> paste and execute   (or a LocalScript in
         StarterPlayerScripts for your own game)
  USE:   aim assist is against the rules of most games and can get an
         account banned or kicked. Use it on private servers, in your
         own place, or with people who agree. Nothing here hides the
         interface or tries to get around anti-cheat.

  ARCHITECTURE (top to bottom)
    1 Services / guard    single-instance guard, services
    2 Theme + Janitor     palette, accent colors, cleanup
    3 Schema + Config     ONE table drives defaults, validation and UI
    4 Persist             settings, 3 profiles, layout (if files exist)
    5 GUI root + Toasts   layers inside PlayerGui, notifications
    6 ENGINE              targeting and aiming (never touches the GUI)
    7 OVERLAY             FOV circle, crosshair, indicator, info, HUD
    8 MENU                window, tabs (built on first open), controls
    9 INPUT + BOOT        key binding, buttons, panic, unload

  HOW THE ENGINE WORKS
    * Players are cached; a frame never searches the map.
    * Each candidate is checked cheap to expensive: alive, team, part,
      distance, projection, FOV, then one visibility raycast.
    * Smart Bone swaps to another body part if the first is hidden.
    * Aim point = part position (filtered) + measured velocity * lead,
      plus projectile drop and your offsets.
    * The camera turns toward it with Smooth, Linear, Spring or Snap
      motion, with dead zone, turn-speed cap and ramp-up.
    * Targets are scanned at a set rate; a locked target is only
      re-checked. The frame loop is bound only while it is needed.
    * The step is wrapped: errors are logged and repeated errors switch
      the assist off instead of crashing the game.
=====================================================================
]]

-- 1 ===================== SERVICES / GUARD =========================
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local StatsService = game:GetService("Stats")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
	warn("[Mrs Aim] This script must run on the client.")
	return
end
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local genv = (typeof(getgenv) == "function" and getgenv()) or _G
if genv.__AIMBELL_UNLOAD then
	pcall(genv.__AIMBELL_UNLOAD)
	genv.__AIMBELL_UNLOAD = nil
end
if genv.__AIMLUST_UNLOAD then -- older aimlust versions
	pcall(genv.__AIMLUST_UNLOAD)
	genv.__AIMLUST_UNLOAD = nil
end
if genv.__MRSAIM_UNLOAD then -- older Mrs Aim versions
	pcall(genv.__MRSAIM_UNLOAD)
	genv.__MRSAIM_UNLOAD = nil
end
if genv.__LULUNOM_UNLOAD then -- older luluNOM versions
	pcall(genv.__LULUNOM_UNLOAD)
	genv.__LULUNOM_UNLOAD = nil
end
if genv.EimbotStop then -- older Eimbot versions
	pcall(genv.EimbotStop)
	genv.EimbotStop = nil
end

local NAME, VERSION = "aimbell", "[beta]"
local BIND_NAME = "AimBell_Step"

-- 2 ===================== THEME + JANITOR ==========================
-- Strict 5-color palette: black, white, two neutral greys (for layering depth, same as ink
-- density in manga shading), and one red accent. No blue/violet/green/gold anywhere anymore.
local T = {
	bg = Color3.fromRGB(0, 0, 0),
	side = Color3.fromRGB(13, 13, 13),
	card = Color3.fromRGB(19, 19, 19),
	cardHi = Color3.fromRGB(29, 29, 29),
	off = Color3.fromRGB(48, 48, 48),
	line = Color3.fromRGB(42, 42, 42),
	text = Color3.fromRGB(245, 245, 245),
	dim = Color3.fromRGB(145, 145, 145),
	good = Color3.fromRGB(245, 245, 245),
	warn = Color3.fromRGB(216, 20, 38),
	bad = Color3.fromRGB(216, 20, 38),
}
local ACCENTS = {
	Crimson = Color3.fromRGB(216, 20, 38),
	White = Color3.fromRGB(245, 245, 245),
}
local ACCENT_NAMES = { "Crimson", "White" }

-- anything that follows the accent registers a function here
local Accent = { color = ACCENTS.Crimson, subs = {} }
function Accent.sub(fn)
	Accent.subs[#Accent.subs + 1] = fn
	fn()
end
function Accent.set(name)
	Accent.color = ACCENTS[name] or ACCENTS.Violet
	for i = 1, #Accent.subs do
		Accent.subs[i]()
	end
end

local App = {
	alive = true,
	panic = false,
	loopBound = false,
	listening = nil,
	btnInput = nil,
	btnStart = nil,
	btnTime = 0,
	btnMoved = false,
	toastN = 0,
	aimOn = false,
	fpsAcc = 0,
	fpsFrames = 0,
	costAcc = 0,
	pingAcc = 0,
	log = {},
	errors = {},
	priorityHeld = false,
	autoLiteApplied = false,
}

local Janitor = { items = {} }
function Janitor.add(item)
	Janitor.items[#Janitor.items + 1] = item
	return item
end
function Janitor.connect(signal, fn)
	return Janitor.add(signal:Connect(fn))
end
function Janitor.clean()
	for i = #Janitor.items, 1, -1 do
		local it = Janitor.items[i]
		local t = typeof(it)
		if t == "RBXScriptConnection" then
			it:Disconnect()
		elseif t == "Instance" then
			it:Destroy()
		elseif t == "function" then
			pcall(it)
		end
		Janitor.items[i] = nil
	end
end

-- 3 ===================== SCHEMA + CONFIG ==========================
local TABS = { "OVERVIEW", "AIM", "ACCURACY", "TARGET", "HUMAN", "ADVANCED", "PRO", "ELITE", "VISUAL", "CONTROLS", "SYSTEM" }
local SCHEMA, S = {}, {}
local function def(tab, key, kind, default, label, extra)
	local e = extra or {}
	e.tab, e.key, e.kind, e.def, e.label = tab, key, kind, default, label
	SCHEMA[#SCHEMA + 1] = e
	S[key] = e
end
local function hdr(tab, label)
	SCHEMA[#SCHEMA + 1] = { tab = tab, kind = "header", label = label }
end

hdr("OVERVIEW", "CONTROL")
def("OVERVIEW", "enabled", "bool", false, "Aim Assist", { desc = "Master switch" })
def("OVERVIEW", "aimMode", "enum", "Hold", "Aim Mode", { opts = { "Hold", "Toggle", "Always" } })
def("OVERVIEW", "aimKey", "key", "MouseButton2", "Aim Key", { desc = "Tap, then press any key or mouse button" })

hdr("AIM", "MOTION")
def("AIM", "method", "enum", "Camera", "Aim Method", { opts = { "Camera", "Mouse" }, desc = "Mouse needs mousemoverel" })
def("AIM", "style", "enum", "Smooth", "Aim Style", { opts = { "Smooth", "Linear", "Spring", "Snap" } })
def("AIM", "smoothing", "num", 35, "Smoothness", { min = 0, max = 100, step = 1, fmt = "%d%%" })
def("AIM", "sensitivity", "num", 1, "Aim Speed", { min = 0.25, max = 3, step = 0.05, fmt = "%.2fx" })
def("AIM", "stiffness", "num", 20, "Spring Stiffness", { min = 4, max = 40, step = 1, fmt = "%d" })
def("AIM", "adaptive", "bool", false, "Adaptive Smoothing", { desc = "Faster far away, finer up close" })
def("AIM", "autoFallback", "bool", true, "Auto Camera Fallback", { desc = "Switches to Mouse aim if the game fights the camera" })
hdr("AIM", "POINT OF AIM")
def("AIM", "targetPart", "enum", "Head", "Aim Part", { opts = { "Head", "Torso", "Root", "Closest" } })
def("AIM", "smartBone", "bool", true, "Smart Bone", { desc = "Uses another body part if blocked" })
def("AIM", "offX", "num", 0, "Offset X", { min = -3, max = 3, step = 0.1, fmt = "%.1f st" })
def("AIM", "offY", "num", 0, "Offset Y", { min = -3, max = 3, step = 0.1, fmt = "%.1f st" })
def("AIM", "axis", "enum", "Both", "Aim Axis", { opts = { "Both", "Horizontal", "Vertical" } })
hdr("AIM", "FINE TUNING")
def("AIM", "deadZone", "num", 0.3, "Dead Zone", { min = 0, max = 3, step = 0.1, fmt = "%.1f deg" })
def("AIM", "maxTurn", "num", 720, "Max Turn Speed", { min = 0, max = 1500, step = 50, fmt = "%d deg/s", zero = "Unlimited" })
def("AIM", "rampUp", "num", 0.1, "Ramp-Up", { min = 0, max = 1, step = 0.05, fmt = "%.2fs" })
def("AIM", "posFilter", "num", 0.2, "Position Filter", { min = 0, max = 0.9, step = 0.05, fmt = "%.2f" })
def("AIM", "magnetRadius", "num", 60, "Magnet Radius", { min = 0, max = 200, step = 5, fmt = "%d px", zero = "Off" })
def("AIM", "magnetBoost", "num", 0.4, "Magnet Boost", { min = 0, max = 2, step = 0.1, fmt = "%.1fx" })

hdr("ACCURACY", "PREDICTION")
def("ACCURACY", "movePredict", "bool", true, "Move Prediction", { desc = "Leads moving targets" })
def("ACCURACY", "leadTime", "num", 0.1, "Lead Time", { min = 0, max = 0.5, step = 0.01, fmt = "%.2fs" })
def("ACCURACY", "predStrength", "num", 1, "Prediction Strength", { min = 0, max = 3, step = 0.05, fmt = "%.2fx" })
def("ACCURACY", "velSmooth", "num", 0.5, "Velocity Smoothing", { min = 0, max = 0.9, step = 0.05, fmt = "%.2f" })
def("ACCURACY", "pingComp", "bool", false, "Ping Compensation", { desc = "Adds your ping to the lead" })
def("ACCURACY", "accelLead", "num", 0.4, "Acceleration Lead", { min = 0, max = 1, step = 0.05, fmt = "%.2f" })
def("ACCURACY", "airLead", "bool", true, "Airborne Lead", { desc = "Accounts for gravity on jumping targets" })
hdr("ACCURACY", "PROJECTILES")
def("ACCURACY", "projSpeed", "num", 0, "Projectile Speed", { min = 0, max = 2000, step = 25, fmt = "%d st/s", zero = "Hitscan" })
def("ACCURACY", "bulletGravity", "num", 0, "Bullet Gravity", { min = 0, max = 1, step = 0.05, fmt = "%.2f" })
def("ACCURACY", "gravityComp", "num", 0, "Manual Drop Comp", { min = 0, max = 3, step = 0.1, fmt = "%.1f" })

hdr("TARGET", "SELECTION")
def("TARGET", "priority", "enum", "Crosshair", "Priority", { opts = { "Crosshair", "Nearest", "Hybrid", "Low HP" }, perRow = 2 })
def("TARGET", "fov", "num", 150, "Aim FOV", { min = 30, max = 600, step = 5, fmt = "%d px" })
def("TARGET", "dynamicFov", "bool", true, "Dynamic FOV", { desc = "Follows camera zoom, grows while locked" })
def("TARGET", "maxDistance", "num", 500, "Max Distance", { min = 25, max = 2000, step = 25, fmt = "%d st" })
hdr("TARGET", "FILTERS")
def("TARGET", "visibleCheck", "bool", true, "Visibility Check", { desc = "Only targets you can see" })
def("TARGET", "teamCheck", "bool", true, "Team Filter", { desc = "Skips your teammates" })
def("TARGET", "teamMode", "enum", "Auto", "Team Detection", { opts = { "Auto", "Team", "Color", "Off" }, perRow = 2 })
def("TARGET", "myRole", "text", "", "My Team/Role Name", { desc = "For games without real Teams (e.g. Prison Life): type your role exactly" })
def("TARGET", "teamDebug", "bool", false, "Team Debug", { desc = "Adds team/role info to the Target HUD card (needs it on, Visual tab)" })
def("TARGET", "ignoreFF", "bool", true, "Ignore Forcefield", { desc = "Skips protected players" })
def("TARGET", "ignoreFriends", "bool", false, "Ignore Friends", { desc = "Never targets your friends" })
def("TARGET", "npcs", "bool", false, "Target NPCs", { desc = "Includes non-player humanoids" })
def("TARGET", "universal", "bool", true, "Universal Targeting", { desc = "Works with custom characters and health systems" })
def("TARGET", "minHealth", "num", 0, "Min Health", { min = 0, max = 100, step = 5, fmt = "%d HP", zero = "Off" })
hdr("TARGET", "LOCKING")
def("TARGET", "lockMode", "bool", false, "Lock Target", { desc = "Off: moving your view switches target instantly. On: stays locked even if you look away." })
def("TARGET", "reacquire", "bool", true, "Reacquire", { desc = "Pick a new target after losing one" })
def("TARGET", "grace", "num", 0.25, "Occlusion Grace", { min = 0, max = 1, step = 0.05, fmt = "%.2fs", zero = "Off" })
def("TARGET", "leash", "num", 75, "Lock Leash", { min = 20, max = 180, step = 5, fmt = "%d deg" })
def("TARGET", "scanRate", "num", 30, "Scan Rate", { min = 10, max = 120, step = 5, fmt = "%d Hz" })

hdr("HUMAN", "HUMANIZE")
def("HUMAN", "humanize", "bool", false, "Humanize", { desc = "Adds wander, delay and misses" })
def("HUMAN", "wander", "num", 0.2, "Wander", { min = 0, max = 2, step = 0.05, fmt = "%.2f st" })
def("HUMAN", "reaction", "num", 0.1, "Reaction Delay", { min = 0, max = 1, step = 0.05, fmt = "%.2fs" })
def("HUMAN", "hitChance", "num", 100, "Hit Chance", { min = 10, max = 100, step = 5, fmt = "%d%%" })
hdr("HUMAN", "AUTO FIRE")
def("HUMAN", "autoFire", "bool", false, "Auto Fire", { desc = "Clicks while on target (needs mouse1click)" })
def("HUMAN", "fireDelay", "num", 0.15, "Fire Delay", { min = 0.05, max = 1, step = 0.05, fmt = "%.2fs" })
def("HUMAN", "fireZone", "num", 14, "Fire Zone", { min = 4, max = 40, step = 1, fmt = "%d px" })

hdr("VISUAL", "FOV CIRCLE")
def("VISUAL", "showFov", "bool", true, "Show FOV Circle")
def("VISUAL", "fovColor", "color", "Crimson", "FOV Color", { opts = ACCENT_NAMES })
def("VISUAL", "fovThickness", "num", 1.5, "FOV Thickness", { min = 0.5, max = 4, step = 0.5, fmt = "%.1f" })
def("VISUAL", "fovTransparency", "num", 0.35, "FOV Transparency", { min = 0, max = 1, step = 0.05, fmt = "%.2f" })
def("VISUAL", "fovFilled", "bool", false, "FOV Fill")
def("VISUAL", "fovHandle", "bool", true, "FOV Drag Handle", { desc = "Drag the circle edge to resize it" })
hdr("VISUAL", "CROSSHAIR")
def("VISUAL", "crosshair", "bool", true, "Crosshair")
def("VISUAL", "crossStyle", "enum", "Plus", "Crosshair Style", { opts = { "Plus", "Dot", "X", "Ring" } })
def("VISUAL", "crossSize", "num", 10, "Crosshair Size", { min = 4, max = 30, step = 1, fmt = "%d px" })
def("VISUAL", "crossThickness", "num", 2, "Crosshair Thickness", { min = 1, max = 5, step = 1, fmt = "%d px" })
def("VISUAL", "crossColor", "color", "White", "Crosshair Color", { opts = ACCENT_NAMES })
hdr("VISUAL", "TARGET")
def("VISUAL", "showIndicator", "bool", true, "Lock Indicator")
def("VISUAL", "showSnapline", "bool", false, "Snapline", { desc = "Line to the target" })
def("VISUAL", "showInfo", "bool", true, "Target Info")
def("VISUAL", "showHealth", "bool", true, "Show Health")
def("VISUAL", "showDistance", "bool", true, "Show Distance")
def("VISUAL", "showLead", "bool", false, "Lead Marker", { desc = "Shows where the prediction is aiming" })
def("VISUAL", "showMeter", "bool", true, "Accuracy Meter", { desc = "Shows how often you are on target" })
def("VISUAL", "targetColor", "color", "White", "Target Color", { opts = ACCENT_NAMES })
def("VISUAL", "lockColor", "color", "Crimson", "Lock Color", { opts = ACCENT_NAMES })
hdr("VISUAL", "PERFORMANCE")
def("VISUAL", "showFps", "bool", false, "FPS Counter")
def("VISUAL", "showPerf", "bool", false, "Performance Monitor", { desc = "Frame time, aim cost and memory" })

hdr("CONTROLS", "PHONE BUTTONS")
def("CONTROLS", "showAimButton", "bool", UserInputService.TouchEnabled, "Aim Button")
def("CONTROLS", "buttonMode", "enum", "Toggle", "Button Mode", { opts = { "Toggle", "Hold" }, desc = "Toggle: tap to latch. Hold: aims while pressed" })
def("CONTROLS", "showSwitchButton", "bool", UserInputService.TouchEnabled, "Swap Button", { desc = "Jumps to the next target" })
def("CONTROLS", "btnScale", "num", 1, "Button Size", { min = 0.6, max = 1.6, step = 0.05, fmt = "%.2fx" })
def("CONTROLS", "btnOpacity", "num", 0.9, "Button Opacity", { min = 0.3, max = 1, step = 0.05, fmt = "%.2f" })
def("CONTROLS", "editLayout", "bool", false, "Move Buttons", { desc = "Drag the buttons where you want them" })
hdr("ADVANCED", "RECOIL AND FIRE")
def("ADVANCED", "recoilComp", "bool", false, "Recoil Compensation", { desc = "Pulls the camera down slightly while firing" })
def("ADVANCED", "recoilStrength", "num", 0.3, "Recoil Strength", { min = 0, max = 1, step = 0.05, fmt = "%.2f" })
def("ADVANCED", "burstFire", "bool", false, "Burst Fire", { desc = "Auto Fire clicks in bursts instead of nonstop" })
def("ADVANCED", "burstCount", "num", 3, "Burst Size", { min = 1, max = 10, step = 1, fmt = "%d clicks" })
def("ADVANCED", "burstGap", "num", 0.35, "Burst Gap", { min = 0.1, max = 1.5, step = 0.05, fmt = "%.2fs" })
hdr("ADVANCED", "LOCK QUALITY")
def("ADVANCED", "multiPoint", "bool", true, "Multi-Point Check", { desc = "Tests 3 points per part so a railing or leaf doesn't break lock" })
def("ADVANCED", "confidenceFilter", "bool", true, "Confidence Filter", { desc = "Ignores targets with erratic or teleporting movement" })
def("ADVANCED", "lockTimeout", "num", 0, "Lock Timeout", { min = 0, max = 20, step = 1, fmt = "%ds", zero = "Off" })
def("ADVANCED", "switchCooldown", "num", 0.08, "Switch Cooldown", { min = 0, max = 1, step = 0.02, fmt = "%.2fs" })
def("ADVANCED", "regenIgnore", "bool", false, "Ignore Regenerating HP", { desc = "Skips a target the instant its health jumps up" })
def("ADVANCED", "finishPriority", "bool", false, "Finish Priority", { desc = "Prefers targets already low on health" })
hdr("ADVANCED", "FEEL")
def("ADVANCED", "flickAssist", "bool", true, "Flick Assist", { desc = "Micro-corrects the last few pixels onto target" })
def("ADVANCED", "shakeComp", "bool", true, "Shake Compensation", { desc = "Ignores sudden camera kicks from explosions or hits" })
def("ADVANCED", "microStable", "bool", true, "Micro-Stabilizer", { desc = "Removes single-frame aim flicker" })
def("ADVANCED", "heightComp", "num", 0, "Height Compensation", { min = -1, max = 1, step = 0.1, fmt = "%.1f", zero = "Off" })
hdr("ADVANCED", "FEEDBACK")
def("ADVANCED", "fovPulse", "bool", true, "FOV Pulse", { desc = "Gently pulses the FOV ring while searching" })
def("ADVANCED", "haptics", "bool", true, "Haptic Feedback", { desc = "Pulses a connected gamepad on lock (no API for phone vibration)" })

hdr("PRO", "COMBAT")
def("PRO", "triggerBot", "bool", false, "Trigger Bot", { desc = "Fires the instant the crosshair is naturally on a target, no aim movement" })
def("PRO", "triggerDelay", "num", 0.08, "Trigger Delay", { min = 0, max = 0.5, step = 0.01, fmt = "%.2fs" })
def("PRO", "fireReset", "bool", true, "Fire Recoil Reset", { desc = "Clears aim momentum right after each shot for a crisp next correction" })
hdr("PRO", "TARGETING")
def("PRO", "falloffCurve", "num", 1, "FOV Falloff Curve", { min = 0.5, max = 3, step = 0.1, fmt = "%.1f" })
def("PRO", "fovAutoShrink", "bool", true, "Auto FOV Shrink", { desc = "Shrinks the FOV ring while no target is near" })
def("PRO", "fovFloor", "num", 40, "FOV Floor", { min = 10, max = 150, step = 5, fmt = "%d px" })
def("PRO", "ignoreName", "text", "", "Ignore Name", { desc = "Never targets this exact player name" })
def("PRO", "safeIdle", "bool", true, "Safe Idle", { desc = "Pauses the assist while your own character isn't spawned" })
hdr("PRO", "FEEL")
def("PRO", "selfPunchFilter", "bool", true, "Self-Punch Filter", { desc = "Ignores your own weapon's screen kick when firing" })
def("PRO", "glowIntensity", "num", 1, "Lock Glow Intensity", { min = 0.3, max = 2, step = 0.1, fmt = "%.1fx" })
def("PRO", "predConfidence", "bool", true, "Confidence-Scaled Lead", { desc = "Reduces prediction on targets with erratic movement" })
hdr("PRO", "HOTKEYS")
def("PRO", "partCycleKey", "key", "V", "Cycle Aim Part Key")
def("PRO", "priorityKey", "key", "LeftAlt", "Hold For Nearest Key", { desc = "Temporarily forces Nearest priority while held" })
hdr("PRO", "DISPLAY AND PERFORMANCE")
def("PRO", "showCount", "bool", true, "Targets In View", { desc = "Shows how many valid targets are inside the FOV" })
def("PRO", "adaptivePerf", "bool", true, "Adaptive Performance", { desc = "Automatically simplifies the UI if your FPS drops" })
def("PRO", "wallmark", "bool", true, "Wallmark", { desc = "Leaves a fading marker where a hidden target was last seen" })
def("PRO", "wallmarkFade", "num", 1.5, "Wallmark Fade", { min = 0.3, max = 4, step = 0.1, fmt = "%.1fs" })

hdr("ELITE", "GAME PROFILES")
def("ELITE", "gameProfiles", "bool", true, "Game Profiles", { desc = "Auto-applies tuned settings for a short list of known games" })
def("ELITE", "profileNotify", "bool", true, "Notify On Match", { desc = "Shows a toast when a known game is detected" })
hdr("ELITE", "WEAPON AWARENESS")
def("ELITE", "weaponFov", "bool", true, "Weapon-Aware FOV", { desc = "Nudges FOV from your equipped tool's name (sniper, shotgun, etc)" })
def("ELITE", "scopeSensitivity", "bool", true, "Scoped Sensitivity Scaling", { desc = "Compensates Smoothness as your camera zooms in" })
def("ELITE", "perWeaponFov", "bool", false, "Per-Weapon FOV Memory", { desc = "Remembers a separate FOV for each weapon you use" })
def("ELITE", "meleeIgnore", "num", 4, "Melee Range Ignore", { min = 0, max = 20, step = 1, fmt = "%d st", zero = "Off" })
hdr("ELITE", "AWARENESS")
def("ELITE", "elevationArrow", "bool", true, "Target Elevation Marker", { desc = "A mark on the FOV ring pointing toward a target above or below view" })
def("ELITE", "selfHpWarn", "bool", true, "Self HP Warning", { desc = "A red screen pulse when your own health drops low" })
def("ELITE", "selfHpThreshold", "num", 30, "Warning Threshold", { min = 5, max = 75, step = 5, fmt = "%d%%" })
hdr("ELITE", "FEEDBACK")
def("ELITE", "fireFlash", "bool", true, "Fire Flash", { desc = "A quick flash each time Auto Fire or Trigger Bot fires" })
def("ELITE", "debugReadout", "bool", false, "Aim Debug Readout", { desc = "Live angle, turn speed and lead numbers for tuning" })
def("ELITE", "distanceUnit", "enum", "Studs", "Distance Unit", { opts = { "Studs", "Meters" } })
hdr("ELITE", "INPUT")
def("ELITE", "touchLatency", "num", 0, "Touch Latency Comp", { min = 0, max = 0.15, step = 0.01, fmt = "%.2fs", zero = "Off" })
hdr("ELITE", "QUALITY OF LIFE")
def("ELITE", "sessionStats", "bool", true, "Session Stats", { desc = "Tracks locks and shots fired for this session" })
def("ELITE", "colorBlind", "bool", false, "Color-Blind Palette", { desc = "High-contrast colors that don't rely on red vs blue" })
def("ELITE", "smartRecovery", "bool", true, "Smart Panic Recovery", { desc = "Resumes automatically if Panic was triggered by an error, never when you triggered it" })

hdr("CONTROLS", "SWIPE GESTURE")
def("CONTROLS", "swipeSwitch", "bool", true, "Swipe To Switch", { desc = "Two-finger swipe cycles the target, left or right" })
def("CONTROLS", "swipeThreshold", "num", 55, "Swipe Sensitivity", { min = 25, max = 150, step = 5, fmt = "%d px" })
hdr("CONTROLS", "KEYS")
def("CONTROLS", "swapKey", "key", "X", "Swap Target Key", { desc = "Tap, then press a key" })

hdr("SYSTEM", "INTERFACE")
def("SYSTEM", "accent", "color", "Crimson", "Accent Color", { opts = ACCENT_NAMES })
def("SYSTEM", "menuKey", "enum", "RightShift", "Menu Key", { opts = { "RightShift", "RightControl", "Insert", "Home" }, perRow = 2 })
def("SYSTEM", "panicKey", "enum", "End", "Panic Key", { opts = { "End", "Delete", "P", "Backspace" }, perRow = 2 })
def("SYSTEM", "notifications", "bool", true, "Notifications")
def("SYSTEM", "liteUI", "bool", false, "Lite UI", { desc = "No animations, easier on old phones" })
def("SYSTEM", "recorder", "bool", true, "Crash Recorder", { desc = "Saves recent events to a file" })

local cfg = {}
local function resetCfg()
	for _, e in ipairs(SCHEMA) do
		if e.key then cfg[e.key] = e.def end
	end
end
resetCfg()

-- Presets only reset how the aim feels (everything except CONTROLS and SYSTEM), so switching one
-- never wipes your menu key, accent color, button layout, or any other personal/device setting.
local PRESET_TABS = { OVERVIEW = true, AIM = true, ACCURACY = true, TARGET = true, HUMAN = true, ADVANCED = true, PRO = true, ELITE = true, VISUAL = true }
local function resetAimFeel()
	for _, e in ipairs(SCHEMA) do
		if e.key and PRESET_TABS[e.tab] then cfg[e.key] = e.def end
	end
end

local function sanitize(e, v)
	if type(v) ~= type(e.def) then return e.def end
	if e.kind == "num" then
		if v ~= v then return e.def end
		return math.clamp(v, e.min, e.max)
	elseif e.kind == "enum" or e.kind == "color" then
		return table.find(e.opts, v) and v or e.def
	elseif e.kind == "key" then
		return (#v > 0 and #v < 32) and v or e.def
	elseif e.kind == "text" then
		return (#v < 40) and v or v:sub(1, 40)
	end
	return v
end
local function loadInto(dst, src)
	for _, e in ipairs(SCHEMA) do
		if e.key then dst[e.key] = sanitize(e, type(src) == "table" and src[e.key] or nil) end
	end
end
local function snapshot()
	local t = {}
	for _, e in ipairs(SCHEMA) do
		if e.key then t[e.key] = cfg[e.key] end
	end
	return t
end

-- Every preset below is a complete, self-contained state: applying one resets everything to
-- default first, then sets only the fields that define its identity. Switching between presets
-- is now always a clean slate, never a blend with whatever was active before.
local PRESETS = {
	["Aim Lock"] = { -- the strongest preset: locks onto whatever's closest to your crosshair and holds it, smoothly
		style = "Spring", stiffness = 27, sensitivity = 1.25, deadZone = 0.12, maxTurn = 1100, rampUp = 0.05, posFilter = 0.22,
		priority = "Crosshair", falloffCurve = 1.6, fov = 230, dynamicFov = true, lockMode = true, reacquire = true,
		smartBone = true, multiPoint = true, confidenceFilter = true, finishPriority = true, visibleCheck = true,
		grace = 0.35, leash = 140, magnetRadius = 130, magnetBoost = 1.0, flickAssist = true, scopeSensitivity = true,
		movePredict = true, leadTime = 0.04, predStrength = 1.1, accelLead = 0.5, predConfidence = true,
		humanize = false, autoFire = true, fireDelay = 0.08, fireZone = 16, fireReset = true, fireFlash = true,
	},
	["Cam Lock"] = { -- the same lock-on feel as Aim Lock, but it never clicks for you -- pure camera control
		style = "Spring", stiffness = 25, sensitivity = 1.15, deadZone = 0.15, maxTurn = 900, rampUp = 0.06, posFilter = 0.25,
		priority = "Crosshair", fov = 200, dynamicFov = true, lockMode = true, reacquire = true, smartBone = true,
		multiPoint = true, visibleCheck = true, grace = 0.4, leash = 110, magnetRadius = 90, magnetBoost = 0.7,
		scopeSensitivity = true, movePredict = true, leadTime = 0.05, predStrength = 1, humanize = false, autoFire = false,
	},
	Headhunter = { -- head-only, no mercy: tight FOV, instant snap, fires the moment it's on target
		style = "Snap", priority = "Crosshair", targetPart = "Head", smartBone = false, fov = 140, dynamicFov = false,
		lockMode = true, reacquire = true, visibleCheck = true, maxDistance = 1200, movePredict = true, leadTime = 0.06,
		humanize = false, autoFire = true, fireDelay = 0.07, fireZone = 10, triggerBot = true, triggerDelay = 0.03, fireReset = true,
	},
	Sniper = { -- for long-range weapons with real bullet travel time: slow, deliberate, drop-compensated
		style = "Smooth", smoothing = 60, sensitivity = 0.8, targetPart = "Head", fov = 80, dynamicFov = true,
		lockMode = true, priority = "Distance", maxDistance = 3000, visibleCheck = true, smartBone = true,
		movePredict = true, leadTime = 0.12, projSpeed = 650, bulletGravity = 0.5, pingComp = true,
		scopeSensitivity = true, humanize = false,
	},
	Legit = { -- looks like a human playing well, not a script
		style = "Smooth", smoothing = 70, fov = 90, targetPart = "Torso", humanize = true, wander = 0.35,
		reaction = 0.15, hitChance = 85, movePredict = false, lockMode = false, maxDistance = 300, visibleCheck = true,
	},
	Casual = { -- barely-there assist: a gentle pull, nothing that feels like aimbot
		style = "Smooth", smoothing = 85, sensitivity = 0.6, fov = 60, targetPart = "Torso", lockMode = false,
		humanize = true, wander = 0.5, reaction = 0.2, hitChance = 70, movePredict = false, magnetRadius = 0,
	},
	Balanced = {
		style = "Smooth", smoothing = 35, fov = 150, targetPart = "Head", humanize = false, movePredict = true,
		leadTime = 0.1, lockMode = true, visibleCheck = true, maxDistance = 500,
	},
	Precise = {
		style = "Spring", stiffness = 22, deadZone = 0.4, movePredict = true, leadTime = 0.08, velSmooth = 0.6,
		posFilter = 0.35, rampUp = 0.12, smartBone = true, visibleCheck = true, fov = 160, humanize = false,
	},
	Aggressive = {
		style = "Snap", fov = 400, targetPart = "Head", movePredict = true, leadTime = 0.12, lockMode = true,
		maxDistance = 2000, deadZone = 0, rampUp = 0, posFilter = 0, humanize = false, maxTurn = 0, magnetRadius = 0,
	},
	Universal = {
		style = "Smooth", smoothing = 40, universal = true, autoFallback = true, grace = 0.25, teamMode = "Auto",
		visibleCheck = true, leash = 75, maxDistance = 700, fov = 170, smartBone = true, movePredict = true,
		leadTime = 0.1, accelLead = 0.4, airLead = true, deadZone = 0.3, rampUp = 0.1, posFilter = 0.25,
	},
	Mobile = {
		showAimButton = true, showSwitchButton = true, buttonMode = "Toggle", style = "Spring", stiffness = 16,
		fov = 170, targetPart = "Head", rampUp = 0.1, deadZone = 0.4, touchLatency = 0.05, visibleCheck = true,
	},
}
local PRESET_NAMES = {
	"Aim Lock", "Cam Lock", "Headhunter", "Sniper", "Legit", "Casual", "Balanced", "Precise", "Aggressive", "Universal", "Mobile",
}

-- A short, honest list of known games by PlaceId. Games can move to a new place over an update,
-- so detection can go stale -- that's why it only fills in sensible defaults, never overrides a saved config.
local GAME_PROFILES = {
	[17625359962] = { name = "Rivals", cfg = {
		style = "Spring", stiffness = 20, fov = 110, targetPart = "Head", smartBone = true,
		movePredict = true, leadTime = 0.05, scanRate = 45, falloffCurve = 1.3, lockMode = false,
	} },
	[286090429] = { name = "Arsenal", cfg = {
		style = "Smooth", smoothing = 40, fov = 130, targetPart = "Head", movePredict = true, leadTime = 0.08,
	} },
	[292439477] = { name = "Phantom Forces", cfg = {
		style = "Spring", stiffness = 18, fov = 100, targetPart = "Head", movePredict = true,
		leadTime = 0.1, projSpeed = 800, bulletGravity = 0.4,
	} },
	[155615604] = { name = "Prison Life", cfg = {
		style = "Smooth", smoothing = 55, fov = 150, targetPart = "Torso", meleeIgnore = 6,
	} },
	[606849621] = { name = "Jailbreak", cfg = {
		style = "Smooth", smoothing = 55, fov = 150, targetPart = "Torso", meleeIgnore = 6,
	} },
}
local GAME_PROFILE_NAMES = { "Rivals", "Arsenal", "Phantom Forces", "Prison Life", "Jailbreak" }

-- 4 ===================== PERSIST ==================================
local layoutDefaults = { menuCX = 0.5, menuCY = 0.5, floatX = 0.06, floatY = 0.3, aimX = 0.88, aimY = 0.62, swX = 0.88, swY = 0.42 }
local layout = {}
for k, v in pairs(layoutDefaults) do layout[k] = v end
local profiles, slot = {}, 1

local FILE = "AimBell_config.json"
local fsOk = typeof(writefile) == "function" and typeof(readfile) == "function" and typeof(isfile) == "function"

local Persist = {}
function Persist.save()
	if not fsOk then return false, "no file API in this environment (session-only)" end
	local pj = {}
	for i = 1, 3 do
		if profiles[i] then pj[tostring(i)] = profiles[i] end
	end
	local ok, err = pcall(function()
		writefile(FILE, HttpService:JSONEncode({ v = 2, cfg = snapshot(), profiles = pj, slot = slot, layout = layout }))
	end)
	return ok, err
end
function Persist.load()
	if not fsOk then return false end
	local ok, data = pcall(function()
		if isfile(FILE) then return HttpService:JSONDecode(readfile(FILE)) end
		return nil
	end)
	if not ok or type(data) ~= "table" then return false end
	loadInto(cfg, data.cfg)
	cfg.editLayout = false
	cfg.enabled = false -- never starts armed
	if type(data.profiles) == "table" then
		for i = 1, 3 do
			local p = data.profiles[tostring(i)]
			if type(p) == "table" then
				local c = {}
				loadInto(c, p)
				profiles[i] = c
			end
		end
	end
	if type(data.slot) == "number" then slot = math.clamp(math.floor(data.slot), 1, 3) end
	if type(data.layout) == "table" then
		for k in pairs(layoutDefaults) do
			if type(data.layout[k]) == "number" then layout[k] = math.clamp(data.layout[k], 0, 1) end
		end
	end
	return true
end
local App_detectedGame = nil
local function applyGameProfileByName(name) -- returns true if a matching profile was found and applied
	for _, profile in pairs(GAME_PROFILES) do
		if profile.name == name then
			resetAimFeel()
			for k, v in pairs(profile.cfg) do
				local e = S[k]
				if e then cfg[k] = sanitize(e, v) end
			end
			App_detectedGame = name
			return true
		end
	end
	return false
end
if cfg.gameProfiles then
	local profile = GAME_PROFILES[game.PlaceId]
	if profile then applyGameProfileByName(profile.name) end
end

local loadedFromDisk = Persist.load()
Accent.color = ACCENTS[cfg.accent] or ACCENTS.Violet

-- 5 ===================== GUI ROOT + TOASTS ========================
local function New(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props) do o[k] = v end
	if parent then o.Parent = parent end
	return o
end
local function Corner(o, r) return New("UICorner", { CornerRadius = UDim.new(0, math.max(2, r * 0.25)) }, o) end
local function Round(o) return New("UICorner", { CornerRadius = UDim.new(1, 0) }, o) end
local function Stroke(o, color, th, tr)
	return New("UIStroke", { Color = color, Thickness = th or 1, Transparency = tr or 0, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, o)
end
local function Label(parent, text, size, color, props)
	local p = {
		BackgroundTransparency = 1, BorderSizePixel = 0, Text = text, Font = Enum.Font.GothamMedium,
		TextSize = size or 13, TextColor3 = color or T.text, TextXAlignment = Enum.TextXAlignment.Left,
	}
	if props then
		for k, v in pairs(props) do p[k] = v end
	end
	return New("TextLabel", p, parent)
end
local function isPointer(i)
	return i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1
end
local function Tw(obj, props, t, style)
	if cfg.liteUI or not t then
		for k, v in pairs(props) do obj[k] = v end
		return
	end
	TweenService:Create(obj, TweenInfo.new(t, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
end
local function setIf(obj, prop, value)
	if obj[prop] ~= value then obj[prop] = value end
end
local gui = New("ScreenGui", {
	Name = "AimBell", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 100,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, nil)
gui.Parent = PlayerGui
Janitor.add(gui)

local function Layer(name, z)
	return New("Frame", { Name = name, BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = z }, gui)
end
local overlay, hudLayer, menuLayer, toastLayer = Layer("Overlay", 1), Layer("Controls", 5), Layer("Menu", 10), Layer("Toasts", 30)

local toastHolder = New("Frame", {
	Name = "Holder", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 40),
	Size = UDim2.fromOffset(340, 150),
}, toastLayer)
New("UIListLayout", { Padding = UDim.new(0, 6), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, toastHolder)

local TOAST = { ok = T.good, info = Accent.color, warn = T.warn, err = T.bad }
local function Notify(msg, kind, force)
	if not App.alive then return end
	if not cfg.notifications and not force then return end
	local col = (kind == "info" or not kind) and Accent.color or (TOAST[kind] or Accent.color)
	App.toastN += 1
	local t = New("TextLabel", {
		AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.fromOffset(0, 0), BackgroundColor3 = T.card,
		BackgroundTransparency = 1, BorderSizePixel = 0, Font = Enum.Font.GothamMedium, TextSize = 13,
		TextColor3 = T.text, TextTransparency = 1, Text = msg, LayoutOrder = App.toastN,
	}, toastHolder)
	Corner(t, 10)
	New("UIPadding", { PaddingLeft = UDim.new(0, 16), PaddingRight = UDim.new(0, 14), PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8) }, t)
	local st = Stroke(t, col, 1, 1)
	local bar = New("Frame", { BackgroundColor3 = col, BorderSizePixel = 0, Size = UDim2.new(0, 3, 1, -12), Position = UDim2.new(0, -10, 0, 6), BackgroundTransparency = 1 }, t)
	Round(bar)
	Tw(t, { BackgroundTransparency = 0.05, TextTransparency = 0 }, 0.15)
	Tw(st, { Transparency = 0.45 }, 0.15)
	Tw(bar, { BackgroundTransparency = 0 }, 0.15)
	local labels = {}
	for _, ch in ipairs(toastHolder:GetChildren()) do
		if ch:IsA("TextLabel") then labels[#labels + 1] = ch end
	end
	table.sort(labels, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
	for i = 1, #labels - 3 do labels[i]:Destroy() end
	task.delay(2.4, function()
		if not App.alive or not t.Parent then return end
		Tw(t, { BackgroundTransparency = 1, TextTransparency = 1 }, 0.2)
		Tw(st, { Transparency = 1 }, 0.2)
		Tw(bar, { BackgroundTransparency = 1 }, 0.2)
		task.delay(0.25, function() t:Destroy() end)
	end)
end

-- Crash recorder: recent events are saved to a file, so after a kick or crash you can see what happened last
local Trace = { lines = {}, dirty = false, previous = nil, unclean = false }
local TRACE_FILE = "AimBell_trace.txt"
function Trace.add(msg)
	local lines = Trace.lines
	lines[#lines + 1] = os.date("%H:%M:%S") .. " " .. msg
	if #lines > 40 then table.remove(lines, 1) end
	Trace.dirty = true
end
function Trace.flush()
	if not Trace.dirty or not fsOk or not cfg.recorder then return end
	Trace.dirty = false
	pcall(writefile, TRACE_FILE, table.concat(Trace.lines, "\n"))
end
function Trace.start()
	if fsOk then
		local ok, text = pcall(function()
			if isfile(TRACE_FILE) then return readfile(TRACE_FILE) end
			return nil
		end)
		if ok and type(text) == "string" and #text > 0 then
			Trace.previous = text
			local last = text:match("([^\n]+)\n*$")
			Trace.unclean = not (last and last:find("UNLOAD", 1, true))
		end
	end
	Trace.add("START aimbell " .. VERSION)
end
function Trace.summary()
	if not Trace.previous then return "No earlier session recorded yet." end
	local lines = {}
	for line in Trace.previous:gmatch("[^\n]+") do lines[#lines + 1] = line end
	local head = Trace.unclean and "Last session did not end with an unload (crash, kick, or the game was closed). Last events:"
		or "Last session ended normally. Last events:"
	return head .. "\n" .. table.concat(lines, "\n", math.max(1, #lines - 5), #lines)
end
-- 6 ===================== ENGINE (no GUI access) ===================
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
pcall(function() rayParams.RespectCanCollide = true end)
local ignoreList, baseCount = {}, 0

local Engine = {
	target = nil, -- the roster entry being aimed at (or previewed)
	locked = false,
	aimHeld = false,
	aimToggled = false,
	buttonHeld = false,
	buttonLatched = false,
	needsRepress = false,
	nextScan = 0,
	fovCurrent = cfg.fov,
	lockSince = 0,
	aimPoint = nil,
	springVel = 0,
	lastFire = 0,
	locks = 0,
	ping = 0,
	localRoot = nil,
	fight = 0,
	camBlocked = false,
	autoMouse = false,
	wroteCam = false,
	preLook = Vector3.zAxis,
	writeLook = Vector3.zAxis,
	applied = 0,
	hiddenSince = nil,
	meter = 0,
	burstState = { fired = 0, pauseUntil = 0 },
	leadOn = false,
	leadX = 0,
	leadY = 0,
	lastLog = 0,
	notice = function(msg, kind) Notify(msg, kind) end,
	out = { c = nil },
	-- ELITE
	shotsFired = 0,
	sessionStart = os.clock(),
	weaponMult = 1,
	zoomScale = 1,
	weaponName = nil,
	weaponCheckAt = 0,
	weaponFovMemory = {},
	fireFlashAt = -10,
	lockFlashAt = -10,
	lastAngle = 0,
	lastAlpha = 0,
	lastLead = 0,
}

local playerList, roster, rosterN = {}, {}, 0
local entries = setmetatable({}, { __mode = "k" })
local npcSet = setmetatable({}, { __mode = "k" })
local npcConn
local friendCache = {}
local ignoreUntil = setmetatable({}, { __mode = "k" })
local cand = { e = {}, s = {}, n = 0 }

local PART_ORDER = {
	Head = { "Head", "UpperTorso", "Torso", "HumanoidRootPart" },
	Torso = { "UpperTorso", "Torso", "HumanoidRootPart", "Head" },
	Root = { "HumanoidRootPart", "UpperTorso", "Torso", "Head" },
}
local BODY = { "Head", "UpperTorso", "Torso", "HumanoidRootPart", "LowerTorso", "LeftUpperArm", "RightUpperArm", "LeftUpperLeg", "RightUpperLeg" }

function Engine.drop()
	Engine.target, Engine.locked = nil, false
	Engine.aimPoint, Engine.springVel = nil, 0
end

function Engine.isAiming()
	if App.panic or not cfg.enabled then return false end
	if Engine.buttonHeld or Engine.buttonLatched or cfg.aimMode == "Always" then return true end
	if cfg.aimMode == "Toggle" then return Engine.aimToggled end
	return Engine.aimHeld
end

function Engine.resetAimState()
	Engine.fight, Engine.camBlocked, Engine.autoMouse, Engine.hiddenSince = 0, false, false, nil
	Engine.aimHeld, Engine.aimToggled, Engine.buttonHeld, Engine.buttonLatched = false, false, false, false
	Engine.needsRepress, Engine.locked = false, false
	Engine.aimPoint, Engine.springVel = nil, 0
end

function Engine.aimInput(down) -- keyboard / mouse aim key
	if App.panic or not cfg.enabled then return end
	if cfg.aimMode == "Hold" then
		Engine.aimHeld = down
	elseif cfg.aimMode == "Toggle" and down then
		Engine.aimToggled = not Engine.aimToggled
	end
	if down then
		Engine.needsRepress = false
		Engine.nextScan = 0
	end
	if not Engine.isAiming() then
		Engine.locked, Engine.needsRepress = false, false
	end
end

-- NPC tracking only runs while "Target NPCs" is on
local function trackNpcs(on)
	if npcConn then
		npcConn:Disconnect()
		npcConn = nil
	end
	npcSet = setmetatable({}, { __mode = "k" })
	if not on then return end
	local function consider(inst)
		if inst:IsA("Humanoid") then
			local m = inst.Parent
			if m and m:IsA("Model") and m ~= LocalPlayer.Character and not Players:GetPlayerFromCharacter(m) then npcSet[m] = true end
		end
	end
	npcConn = Workspace.DescendantAdded:Connect(consider)
	task.spawn(function()
	local function startShine()
		shine.Position = UDim2.fromScale(-0.3, 0.5)
		TweenService:Create(shine, TweenInfo.new(2.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { Position = UDim2.fromScale(1.3, 0.5) }):Play()
	end
		local n = 0
		for _, inst in ipairs(Workspace:GetDescendants()) do
			consider(inst)
			n += 1
			if n % 400 == 0 then task.wait() end
		end
	end)
end
Janitor.add(function() trackNpcs(false) end)

local function entryOf(model, player)
	local e = entries[model]
	if not e then
		e = { model = model, player = player, vel = Vector3.zero, cache = {}, c = {} }
		entries[model] = e
	end
	return e
end

local function refreshRoster()
	local n = 0
	for i = 1, #playerList do
		local pl = playerList[i]
		local ch = pl ~= LocalPlayer and pl.Character
		if ch then
			n += 1
			local e = entryOf(ch, pl)
			table.clear(e.cache) -- body parts change when a character respawns
			roster[n] = e
		end
	end
	if cfg.npcs then
		for m in pairs(npcSet) do
			if m.Parent then
				n += 1
				local e = entryOf(m, nil)
				table.clear(e.cache)
				roster[n] = e
			end
		end
	end
	for i = n + 1, rosterN do roster[i] = nil end
	rosterN = n
end

local function getPart(e, name)
	local cached = e.cache[name]
	if cached == nil or (cached and not cached.Parent) then
		local found = e.model:FindFirstChild(name)
		cached = (found and found:IsA("BasePart")) and found or false
		e.cache[name] = cached
	end
	return cached or nil
end

local function anyPart(e)
	return e.model.PrimaryPart or e.model:FindFirstChildWhichIsA("BasePart")
end

-- team detection: Team objects, team colors, or both
local function firstPart(e, order)
	for i = 1, #order do
		local p = getPart(e, order[i])
		if p then return p end
	end
	return nil
end

-- a wall check that sees through glass and other near-invisible parts
local function castVisible(origin, pos, model)
	local dir = pos - origin
	local result, added = false, false
	for _ = 1, 3 do
		local hit = Workspace:Raycast(origin, dir, rayParams)
		if not hit then
			result = true
			break
		end
		local inst = hit.Instance
		if inst:IsDescendantOf(model) then
			result = true
			break
		end
		if inst.Transparency >= 0.95 then
			ignoreList[#ignoreList + 1] = inst
			rayParams.FilterDescendantsInstances = ignoreList
			added = true
		else
			break
		end
	end
	if added then
		for k = #ignoreList, baseCount + 1, -1 do ignoreList[k] = nil end
		rayParams.FilterDescendantsInstances = ignoreList
	end
	return result
end

-- Multi-Point Check: a thin railing or a leaf hides the center point but not the edges,
-- so three points are tried before the target counts as blocked.
local function isVisible(origin, pos, model, part)
	if castVisible(origin, pos, model) then return true end
	if not cfg.multiPoint or not part then return false end
	local r = part.CFrame.RightVector * (part.Size.X * 0.3 + 0.2)
	return castVisible(origin, pos + r, model) or castVisible(origin, pos - r, model)
end

-- measured velocity and acceleration (position change over time) are steadier than physics values for other players
local function trackVelocity(e, now)
	local root = getPart(e, "HumanoidRootPart") or getPart(e, "Torso") or getPart(e, "UpperTorso") or anyPart(e)
	if not root then return end
	local pos = root.Position
	if not e.lastPos then
		e.vel, e.acc, e.lastPos, e.lastTime = root.AssemblyLinearVelocity, Vector3.zero, pos, now
		return
	end
	local elapsed = now - e.lastTime
	if elapsed < 0.016 then return end
	local measured = (pos - e.lastPos) / elapsed
	if measured.Magnitude > 200 then
		measured = Vector3.zero -- teleport or respawn
		e.erraticUntil = now + 0.3 -- Confidence Filter: don't trust this target for a moment
	end
	local keep = cfg.velSmooth ^ (elapsed * 60)
	local newVel = measured + (e.vel - measured) * keep
	local accNow = (newVel - e.vel) / elapsed
	if accNow.Magnitude > 80 then accNow = accNow.Unit * 80 end
	e.acc = e.acc + (accNow - e.acc) * 0.2
	e.vel, e.lastPos, e.lastTime = newVel, pos, now
end

-- Fills and returns e.c, or nil. Checks run from cheap to expensive.
local function resolve(e, cam, camPos, cx, cy, radius, useFov, needVis)
	local function getHumanoid(e)
		local h = e.humanoid
		if not h or h.Parent ~= e.model then
			h = e.model:FindFirstChildOfClass("Humanoid")
			e.humanoid = h
		end
		return h
	end

	-- Not every game uses Roblox's built-in Team service -- Prison Life and several similar games
	-- hand out roles (Police, Prisoner, Sheriff...) through their own leaderstat or attribute instead,
	-- which leaves Player.Team and Player.Neutral at their defaults for everyone and makes Team/Color
	-- checks silently do nothing. This reads a few common role-value spots as a fallback.
	local ROLE_KEYS = { "Team", "Role", "Side", "Faction", "Job" }
	local function roleValue(pl)
		for _, key in ipairs(ROLE_KEYS) do
			local ok, attr = pcall(pl.GetAttribute, pl, key)
			if ok and type(attr) == "string" and attr ~= "" then return attr end
		end
		local stats = pl:FindFirstChild("leaderstats")
		if stats then
			for _, key in ipairs(ROLE_KEYS) do
				local v = stats:FindFirstChild(key)
				if v and type(v.Value) == "string" and v.Value ~= "" then return v.Value end
			end
		end
		return nil
	end

	local function sameTeam(pl)
		local mode = cfg.teamMode
		if mode == "Off" then return false end
		local lt = LocalPlayer.Team
		if (mode == "Team" or mode == "Auto") and lt ~= nil and pl.Team == lt then return true end
		if mode == "Color" or (mode == "Auto" and lt == nil) then
			if (not LocalPlayer.Neutral) and (not pl.Neutral) and pl.TeamColor == LocalPlayer.TeamColor then return true end
		end
		if cfg.myRole ~= "" then -- manual override: compare against the role name you typed in, wherever it's found
			local mine, theirs = cfg.myRole:lower(), roleValue(pl)
			if theirs and theirs:lower() == mine then return true end
		elseif mode == "Auto" and lt == nil then -- Auto with no real Team object: try the same heuristic unprompted
			local mine, theirs = roleValue(LocalPlayer), roleValue(pl)
			if mine and theirs and mine:lower() == theirs:lower() then return true end
		end
		return false
	end

	local function isFriend(player)
		local cached = friendCache[player.UserId]
		if cached ~= nil then return cached end
		friendCache[player.UserId] = false
		task.spawn(function()
			local ok, result = pcall(function() return LocalPlayer:IsFriendsWith(player.UserId) end)
			friendCache[player.UserId] = ok and result or false
		end)
		return false
	end

	local function pickPart(e, cam, cx, cy)
		local mode = cfg.targetPart
		local result
		if mode ~= "Closest" then
			result = firstPart(e, PART_ORDER[mode])
		else
			local best, bd = nil, math.huge
			for i = 1, #BODY do
				local p = getPart(e, BODY[i])
				if p then
					local v = cam:WorldToViewportPoint(p.Position)
					if v.Z > 0 then
						local dx, dy = v.X - cx, v.Y - cy
						local d = dx * dx + dy * dy
						if d < bd then best, bd = p, d end
					end
				end
			end
			result = best or firstPart(e, PART_ORDER.Head)
		end
		if not result and cfg.universal then result = anyPart(e) end -- custom characters with unusual part names
		return result
	end

	local function fallbackPart(e, camPos, skip) -- Smart Bone
		local order = PART_ORDER.Head
		for i = 1, #order do
			local p = getPart(e, order[i])
			if p and p ~= skip and isVisible(camPos, p.Position, e.model, p) then return p end
		end
		return nil
	end

	local hum = getHumanoid(e)
	local hp, maxHp
	if hum then
		if hum.Health <= 0 then return nil end
		hp, maxHp = hum.Health, hum.MaxHealth
	elseif cfg.universal then
		hp, maxHp = 100, 100 -- custom characters without a Humanoid
	else
		return nil
	end
	if hp < cfg.minHealth then return nil end
	local pl = e.player
	if pl then
		if cfg.teamCheck and sameTeam(pl) then return nil end
		if cfg.ignoreFriends and isFriend(pl) then return nil end
		if cfg.ignoreName ~= "" and pl.Name:lower() == cfg.ignoreName:lower() then return nil end
	end
	if cfg.ignoreFF and e.model:FindFirstChildOfClass("ForceField") then return nil end
	local ig = ignoreUntil[e.model]
	if ig and ig > os.clock() then return nil end
	if cfg.confidenceFilter and e.erraticUntil and e.erraticUntil > os.clock() then return nil end
	if cfg.regenIgnore then
		if e.prevHp and hp > e.prevHp + 1 then
			e.prevHp = hp
			return nil
		end
		e.prevHp = hp
	end
	local part = pickPart(e, cam, cx, cy)
	if not part then return nil end
	local pos = part.Position
	local root = Engine.localRoot
	local origin = (root and root.Parent) and root.Position or camPos
	local wd = (pos - origin).Magnitude
	if wd > cfg.maxDistance then return nil end
	if cfg.meleeIgnore > 0 and wd < cfg.meleeIgnore then return nil end
	local v = cam:WorldToViewportPoint(pos)
	if v.Z <= 0 then return nil end
	local dx, dy = v.X - cx, v.Y - cy
	local sd = math.sqrt(dx * dx + dy * dy)
	if useFov and sd > radius then return nil end
	if needVis and cfg.visibleCheck and not isVisible(camPos, pos, e.model, part) then
		part = cfg.smartBone and fallbackPart(e, camPos, part) or nil
		if not part then return nil end
		pos = part.Position
		v = cam:WorldToViewportPoint(pos)
		if v.Z <= 0 then return nil end
		dx, dy = v.X - cx, v.Y - cy
		sd = math.sqrt(dx * dx + dy * dy)
		wd = (pos - origin).Magnitude
	end
	local c = e.c
	c.e, c.part, c.hum, c.wd, c.sd, c.sx, c.sy, c.hp, c.maxHp = e, part, hum, wd, sd, v.X, v.Y, hp, maxHp
	if cfg.teamDebug then
		c.teamInfo = pl
			and ("Team: %s   Role: %s"):format(pl.Team and pl.Team.Name or "none", roleValue(pl) or "none")
			or "NPC (no player)"
	else
		c.teamInfo = nil
	end
	return c
end

local function curved(value, span, exp)
	if exp == 1 then return value end
	local span2 = math.max(span, 1)
	return (math.clamp(value, 0, span2) / span2) ^ exp * span2 -- reshapes how strongly the FOV center is preferred
end

local function scan(cam, camPos, cx, cy, radius, hysteresis)
	local n, bestE, bestS = 0, nil, math.huge
	local mode = App.priorityHeld and "Nearest" or cfg.priority
	local needVel = cfg.movePredict or cfg.projSpeed > 0 or cfg.pingComp
	local now = os.clock()
	for i = 1, rosterN do
		local e = roster[i]
		if needVel then trackVelocity(e, now) end
		local c = resolve(e, cam, camPos, cx, cy, radius, true, true)
		if c then
			local s
			if mode == "Crosshair" then
				s = curved(c.sd, radius, cfg.falloffCurve)
			elseif mode == "Nearest" then
				s = c.wd
			elseif mode == "Low HP" then
				s = c.hp
			else
				s = curved(c.sd, radius, cfg.falloffCurve) + c.wd * 0.8
			end
			if cfg.finishPriority then s -= (100 - math.clamp(c.hp, 0, 100)) * 0.5 end -- a hurt target scores lower, so it is picked first
			n += 1
			cand.e[n], cand.s[n] = e, s
			local adj = (hysteresis and e == Engine.target) and s * 0.8 or s -- the current target keeps a small lead
			if adj < bestS then bestS, bestE = adj, e end
		end
	end
	cand.n = n
	return bestE
end

-- next-best target, used by the SWAP button
function Engine.swap()
	local cam = Workspace.CurrentCamera
	if not cam then return nil end
	local vp = cam.ViewportSize
	scan(cam, cam.CFrame.Position, vp.X * 0.5, vp.Y * 0.5, Engine.fovCurrent, false)
	local cur, curScore = Engine.target, nil
	for i = 1, cand.n do
		if cand.e[i] == cur then
			curScore = cand.s[i]
			break
		end
	end
	local pick, pickScore, lowest, lowScore = nil, math.huge, nil, math.huge
	for i = 1, cand.n do
		local e, s = cand.e[i], cand.s[i]
		if e ~= cur then
			if s < lowScore then lowest, lowScore = e, s end
			if curScore and s > curScore and s < pickScore then pick, pickScore = e, s end
		end
	end
	pick = pick or lowest
	if pick then
		Engine.target, Engine.locked, Engine.needsRepress = pick, Engine.isAiming(), false
		Engine.lockSince, Engine.aimPoint, Engine.springVel = os.clock(), nil, 0
	end
	return pick
end

-- turning speed for this frame (0..1 of the remaining angle)
function Engine.aim(c, dt, now, cam, camPos)
	local function turnAlpha(angle, dt, now, sd)
		local smooth = cfg.smoothing / 100
		local speed = cfg.sensitivity * Engine.zoomScale
		local adapt = cfg.adaptive and math.clamp(0.4 + angle / 25, 0.4, 2) or 1
		local alpha
		if cfg.style == "Snap" then
			alpha = 1
		elseif cfg.style == "Linear" then -- constant turning speed
			local rate = (60 + (1 - smooth) * 840) * speed * adapt
			alpha = math.min(1, rate * dt / angle)
		elseif cfg.style == "Spring" then -- critically damped spring: eases in and out, never overshoots
			local s, h = cfg.stiffness * speed, math.min(dt, 1 / 30)
			Engine.springVel += (s * s * angle - 2 * s * Engine.springVel) * h
			alpha = math.clamp(Engine.springVel * dt / angle, 0, 1)
		else -- exponential ease
			local rate = (2 + (1 - smooth) * 28) * speed * adapt
			alpha = 1 - math.exp(-rate * dt)
		end
		if cfg.magnetRadius > 0 and cfg.magnetBoost > 0 and sd < cfg.magnetRadius then
			alpha = math.min(1, alpha * (1 + cfg.magnetBoost * (1 - sd / cfg.magnetRadius))) -- stronger pull near the target
		end
		if cfg.flickAssist and sd < 20 then
			alpha = alpha + (1 - alpha) * 0.5 -- halves the remaining distance on the final approach, independent of Magnet
		end
		if cfg.rampUp > 0 then
			local r = math.clamp((now - Engine.lockSince) / cfg.rampUp, 0, 1)
			alpha *= r * r * (3 - 2 * r)
		end
		if cfg.maxTurn > 0 then alpha = math.min(alpha, cfg.maxTurn * dt / angle) end
		return math.clamp(alpha, 0, 1)
	end

	if cfg.humanize and now - Engine.lockSince < cfg.reaction then return end
	local camCF = cam.CFrame
	local raw = c.part.Position
	if cfg.posFilter > 0 and Engine.aimPoint then
		raw = raw + (Engine.aimPoint - raw) * (cfg.posFilter ^ (dt * 60)) -- smooths network jitter in the position
	end
	Engine.aimPoint = raw

	local dist = (raw - camPos).Magnitude
	local lead = 0
	if cfg.movePredict then lead += cfg.leadTime end
	if cfg.projSpeed > 0 then lead += dist / cfg.projSpeed end
	if cfg.pingComp then lead += Engine.ping / 1000 end
	if cfg.touchLatency > 0 then lead += cfg.touchLatency end
	lead *= cfg.predStrength
	if cfg.predConfidence and c.e.erraticUntil and c.e.erraticUntil > now then lead *= 0.3 end -- trust erratic movement less
	Engine.lastLead = lead
	local pos = raw
	if lead > 0 then
		trackVelocity(c.e, now)
		local v, a = c.e.vel, c.e.acc or Vector3.zero
		local air = cfg.airLead and c.hum and c.hum.FloorMaterial == Enum.Material.Air
		local vertical = air and (v.Y * lead - 0.5 * Workspace.Gravity * lead * lead) or (math.clamp(v.Y, -30, 30) * lead)
		pos += Vector3.new(v.X * lead, vertical, v.Z * lead)
		if cfg.accelLead > 0 then pos += Vector3.new(a.X, 0, a.Z) * (0.5 * lead * lead * cfg.accelLead) end
	end
	if cfg.projSpeed > 0 and cfg.bulletGravity > 0 then
		local t = dist / cfg.projSpeed
		pos += Vector3.new(0, 0.5 * Workspace.Gravity * cfg.bulletGravity * t * t, 0)
	end
	if cfg.gravityComp > 0 then pos += Vector3.new(0, cfg.gravityComp * dist / 100, 0) end
	if cfg.offX ~= 0 or cfg.offY ~= 0 then pos += camCF.RightVector * cfg.offX + camCF.UpVector * cfg.offY end
	if cfg.humanize and cfg.wander > 0 then -- slow drifting instead of random shaking
		pos += Vector3.new(math.noise(now * 2.1, 1.7, 0), math.noise(now * 1.9, 5.3, 0), math.noise(now * 2.3, 9.1, 0)) * 2 * cfg.wander
	end
	if cfg.recoilComp and now - Engine.lastFire < 0.25 then -- Recoil Compensation: nudge the point of aim up a little while firing
		pos += camCF.UpVector * (cfg.recoilStrength * dist * 0.02)
	end
	if cfg.showLead then
		local mv = cam:WorldToViewportPoint(pos)
		Engine.leadOn, Engine.leadX, Engine.leadY = mv.Z > 0, mv.X, mv.Y
	end
	if (pos - camPos).Magnitude < 0.5 then return end

	if cfg.heightComp ~= 0 then pos += Vector3.new(0, cfg.heightComp * dist / 100, 0) end

	local look = camCF.LookVector
	local filterKicks = cfg.shakeComp or (cfg.selfPunchFilter and now - Engine.lastFire < 0.15)
	if filterKicks then -- Shake / Self-Punch: ignore a sudden uncommanded camera kick (explosions, hits, your own weapon's recoil)
		if not Engine.shakeLook then Engine.shakeLook = look end
		local kick = math.deg(math.acos(math.clamp(look:Dot(Engine.shakeLook), -1, 1)))
		if kick > 15 and not Engine.wroteCam then
			look = Engine.shakeLook
		else
			Engine.shakeLook = (Engine.shakeLook + (look - Engine.shakeLook) * 0.3).Unit
		end
	end
	local dir = (pos - camPos).Unit
	if cfg.axis == "Horizontal" then -- turn left and right only, keep the pitch
		local flat = Vector3.new(dir.X, 0, dir.Z)
		if flat.Magnitude > 0.001 then
			flat = flat.Unit
			local h = math.sqrt(math.max(0, 1 - look.Y * look.Y))
			dir = Vector3.new(flat.X * h, look.Y, flat.Z * h)
		end
	elseif cfg.axis == "Vertical" then -- pitch only, keep the heading
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude > 0.001 then
			flat = flat.Unit
			local h = math.sqrt(math.max(0, 1 - dir.Y * dir.Y))
			dir = Vector3.new(flat.X * h, dir.Y, flat.Z * h)
		end
	end

	local angle = math.deg(math.acos(math.clamp(look:Dot(dir), -1, 1)))
	if angle < math.max(cfg.deadZone, 0.01) then
		Engine.springVel = 0
		return
	end
	local alpha = turnAlpha(angle, dt, now, c.sd)
	Engine.lastAngle, Engine.lastAlpha = angle, alpha

	local useMouse = (cfg.method == "Mouse" or Engine.autoMouse) and typeof(mousemoverel) == "function"
	if useMouse then
		local v = cam:WorldToViewportPoint(pos)
		local vp = cam.ViewportSize
		local dx, dy = (v.X - vp.X * 0.5) * alpha, (v.Y - vp.Y * 0.5) * alpha
		if cfg.axis == "Horizontal" then dy = 0 elseif cfg.axis == "Vertical" then dx = 0 end
		dx, dy = math.clamp(dx, -350, 350), math.clamp(dy, -350, 350) -- bug fix: an unclamped snap could send one huge, suspicious mouse delta
		pcall(mousemoverel, dx, dy)
	else
		local goal = CFrame.lookAt(camPos, camPos + dir)
		local newCF = alpha >= 0.999 and goal or camCF:Lerp(goal, alpha)
		if cfg.microStable and Engine.lastWrittenLook then -- Micro-Stabilizer: removes single-frame flicker left over after smoothing
			local blended = (newCF.LookVector + Engine.lastWrittenLook * 0.2).Unit
			newCF = CFrame.lookAt(camPos, camPos + blended)
		end
		Engine.preLook, Engine.writeLook, Engine.applied, Engine.wroteCam = look, newCF.LookVector, angle * alpha, true
		Engine.lastWrittenLook = newCF.LookVector
		cam.CFrame = newCF
	end
end

local HapticService = game:GetService("HapticService")
local function doClick(now)
	if cfg.burstFire then
		local b = Engine.burstState
		if now < b.pauseUntil then return false end
		if now - Engine.lastFire < cfg.fireDelay then return false end
		Engine.lastFire = now
		pcall(mouse1click)
		b.fired += 1
		if b.fired >= cfg.burstCount then
			b.fired, b.pauseUntil = 0, now + cfg.burstGap
		end
	else
		if now - Engine.lastFire < cfg.fireDelay then return false end
		Engine.lastFire = now
		pcall(mouse1click)
	end
	if cfg.fireReset then -- Fire Recoil Reset: the next correction starts crisp instead of carrying old momentum
		Engine.springVel = 0
	end
	Engine.shotsFired += 1
	if cfg.fireFlash then Engine.fireFlashAt = now end
	return true
end

-- Trigger Bot: fires the instant the crosshair is naturally over a target, with no camera movement at all
-- one engine tick. returns true while actively aiming.
function Engine.step(dt, now)
	local function targetName(e)
		return e.player and e.player.Name or e.model.Name
	end

	local function pulseHaptic()
		if not cfg.haptics then return end
		pcall(function()
			if HapticService:IsVibrationSupported(Enum.UserInputType.Gamepad1) then
				HapticService:SetMotor(Enum.UserInputType.Gamepad1, Enum.VibrationMotor.Small, 0.6)
				task.delay(0.08, function()
					pcall(HapticService.SetMotor, HapticService, Enum.UserInputType.Gamepad1, Enum.VibrationMotor.Small, 0)
				end)
			end
		end)
	end

	local function maybeFire(c, now)
		if not cfg.autoFire or typeof(mouse1click) ~= "function" or c.sd > cfg.fireZone then return end
		doClick(now)
	end

	local function triggerCheck(c, now)
		if not cfg.triggerBot or typeof(mouse1click) ~= "function" then
			Engine.triggerSince = nil
			return
		end
		if c and c.sd <= cfg.fireZone then
			Engine.triggerSince = Engine.triggerSince or now
			if now - Engine.triggerSince >= cfg.triggerDelay then doClick(now) end
		else
			Engine.triggerSince = nil
		end
	end

	local out = Engine.out
	out.c = nil
	local cam = Workspace.CurrentCamera
	if not cam then return false end
	if cfg.safeIdle then -- Safe Idle: do nothing while your own character isn't alive and spawned
		local char = LocalPlayer.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not (hum and hum.Health > 0) then return false end
	end
	local vp = cam.ViewportSize
	local cx, cy = vp.X * 0.5, vp.Y * 0.5
	local camCF = cam.CFrame
	local camPos = camCF.Position

	-- Did the game undo our last camera write? Games with their own camera script do.
	if Engine.wroteCam then
		Engine.wroteCam = false
		if Engine.applied > 1.5 then
			local back = math.deg(math.acos(math.clamp(camCF.LookVector:Dot(Engine.preLook), -1, 1)))
			if back < Engine.applied * 0.3 then
				Engine.fight += 1
			else
				Engine.fight = math.max(0, Engine.fight - 1)
			end
			if Engine.fight >= 12 and not Engine.camBlocked then
				Engine.camBlocked = true
				if cfg.autoFallback and typeof(mousemoverel) == "function" then
					Engine.autoMouse = true
					Trace.add("CAMERA FOUGHT BACK: MOUSE AIM")
					Engine.notice("THIS GAME FIGHTS THE CAMERA - SWITCHED TO MOUSE AIM", "warn")
				else
					Trace.add("CAMERA FOUGHT BACK: NO FALLBACK")
					Engine.notice("THIS GAME CONTROLS THE CAMERA - ASSIST CAN'T STEER IT HERE", "warn")
				end
			end
		end
	end

	-- dynamic FOV: scales with camera zoom and grows slightly while locked
	Engine.zoomScale = cfg.scopeSensitivity and math.clamp(cam.FieldOfView / 70, 0.4, 1) or 1
	if now - Engine.weaponCheckAt >= 0.5 then -- weapon name rarely changes; no need to check every frame
		Engine.weaponCheckAt = now
		local tool = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Tool")
		local toolName = tool and tool.Name:lower() or nil
		if toolName ~= Engine.weaponName then
			if cfg.perWeaponFov and Engine.weaponName then Engine.weaponFovMemory[Engine.weaponName] = cfg.fov end
			Engine.weaponName = toolName
			if cfg.perWeaponFov and toolName and Engine.weaponFovMemory[toolName] then
				cfg.fov = Engine.weaponFovMemory[toolName]
				Engine.fovUiDirty = true -- the FOV slider (defined later, in the menu) syncs itself when it sees this
			end
		end
		if cfg.weaponFov and toolName then
			if toolName:find("sniper") or toolName:find("scope") or toolName:find("bolt") then
				Engine.weaponMult = 0.65
			elseif toolName:find("shotgun") or toolName:find("smg") or toolName:find("pistol") or toolName:find("knife") then
				Engine.weaponMult = 1.3
			else
				Engine.weaponMult = 1
			end
		else
			Engine.weaponMult = 1
		end
	end

	local goal = cfg.fov * (cfg.weaponFov and Engine.weaponMult or 1)
	if cfg.dynamicFov then
		goal = goal * (70 / math.clamp(cam.FieldOfView, 10, 120))
		if Engine.locked then goal = goal * 1.25 end
	end
	if cfg.fovAutoShrink and not Engine.target then goal = goal * 0.6 end -- Auto FOV Shrink: smaller ring while idle
	goal = math.max(goal, cfg.fovFloor) -- FOV Floor: never shrinks past this, even fully zoomed in
	Engine.fovCurrent += (goal - Engine.fovCurrent) * (1 - math.exp(-12 * dt))
	local radius = Engine.fovCurrent

	local aiming = Engine.isAiming()
	local c
	if aiming then
		local t = Engine.target
		if t and Engine.locked then
			c = resolve(t, cam, camPos, cx, cy, radius, not cfg.lockMode, true)
			if c then
				Engine.hiddenSince = nil
				if cfg.lockMode then -- leash: let go of targets that end up far behind you
					local d = (c.part.Position - camPos).Unit
					if math.deg(math.acos(math.clamp(camCF.LookVector:Dot(d), -1, 1))) > cfg.leash then c = nil end
				end
			elseif cfg.grace > 0 or cfg.wallmark then -- brief cover: keep tracking for a moment, and/or leave a wallmark
				local c2 = resolve(t, cam, camPos, cx, cy, radius, not cfg.lockMode, false)
				if c2 then
					Engine.hiddenSince = Engine.hiddenSince or now
					if cfg.wallmark then Engine.ghost = { x = c2.sx, y = c2.sy, t = now } end
					if cfg.grace > 0 and now - Engine.hiddenSince <= cfg.grace then c = c2 end
				end
			end
			if not c then
				Engine.target, Engine.locked, Engine.nextScan = nil, false, 0
				Engine.aimPoint, Engine.springVel, Engine.hiddenSince = nil, 0, nil
				if not cfg.reacquire then Engine.needsRepress = true end
				if now - Engine.lastLog > 1 then
					Engine.lastLog = now
					Trace.add("LOST TARGET")
				end
			end
		end
		if not Engine.locked then
			if not Engine.needsRepress and now >= Engine.nextScan then
				Engine.nextScan = now + 1 / cfg.scanRate
				local best = scan(cam, camPos, cx, cy, radius, false)
				if best then
					c = resolve(best, cam, camPos, cx, cy, radius, true, true)
					if c then
						if cfg.humanize and math.random(100) > cfg.hitChance then
							ignoreUntil[best.model] = now + 1.5 -- missed this one on purpose
							c = nil
						else
							Engine.target, Engine.locked = best, true
							Engine.lockSince, Engine.aimPoint, Engine.springVel, Engine.hiddenSince = now, nil, 0, nil
							Engine.locks += 1
							Engine.lockFlashAt = now
							pulseHaptic()
							if now - Engine.lastLog > 1 then
								Engine.lastLog = now
								Trace.add(("LOCK %s %dst"):format(targetName(best), math.floor(c.wd)))
							end
						end
					end
				end
			end
		elseif cfg.lockTimeout > 0 and now - Engine.lockSince > cfg.lockTimeout then
			Trace.add("LOCK TIMEOUT")
			Engine.target, Engine.locked, Engine.nextScan = nil, false, 0
			Engine.aimPoint, Engine.springVel = nil, 0
		elseif not cfg.lockMode and now >= Engine.nextScan then
			Engine.nextScan = now + 1 / (cfg.scanRate * 0.66)
			local best = scan(cam, camPos, cx, cy, radius, true)
			if best and best ~= Engine.target and now - Engine.lockSince >= cfg.switchCooldown then
				local c2 = resolve(best, cam, camPos, cx, cy, radius, true, true)
				if c2 then
					Engine.target, Engine.lockSince, Engine.aimPoint, Engine.springVel = best, now, nil, 0
					c = c2
				end
			elseif Engine.target then
				c = resolve(Engine.target, cam, camPos, cx, cy, radius, true, false)
			end
		end
		if c and Engine.locked then
			Engine.aim(c, dt, now, cam, camPos)
			maybeFire(c, now)
			Engine.meter += ((c.sd <= cfg.fireZone and 1 or 0) - Engine.meter) * (1 - math.exp(-2 * dt)) -- how often we are on target
		end
	else
		Engine.locked = false
		if cfg.showIndicator or cfg.showInfo or cfg.showSnapline then -- idle preview of who would be targeted
			if now >= Engine.nextScan then
				Engine.nextScan = now + 0.1
				Engine.target = scan(cam, camPos, cx, cy, radius, true)
			end
			local t = Engine.target
			if t then
				c = resolve(t, cam, camPos, cx, cy, radius, true, false)
				if not c then Engine.target = nil end
			end
		else
			Engine.target = nil
		end
	end

	if c then out.c = c end
	triggerCheck(c, now)
	return aiming
end

-- player list cache (no GetPlayers allocation per scan)
for _, p in ipairs(Players:GetPlayers()) do playerList[#playerList + 1] = p end
Janitor.connect(Players.PlayerAdded, function(p)
	if not table.find(playerList, p) then playerList[#playerList + 1] = p end
end)
Janitor.connect(Players.PlayerRemoving, function(p)
	local i = table.find(playerList, p)
	if i then table.remove(playerList, i) end
	if Engine.target and Engine.target.player == p then Engine.drop() end
end)

-- local character lifecycle (respawn safe)
local function onLocalChar(char)
	ignoreList[1] = char
	baseCount = 1
	for k = #ignoreList, 2, -1 do ignoreList[k] = nil end
	rayParams.FilterDescendantsInstances = ignoreList
	Engine.drop()
	Engine.localRoot = nil
	task.spawn(function()
		local root = char:WaitForChild("HumanoidRootPart", 5)
		if App.alive and LocalPlayer.Character == char then Engine.localRoot = root end
	end)
end
Janitor.connect(LocalPlayer.CharacterAdded, onLocalChar)
Janitor.connect(LocalPlayer.CharacterRemoving, function()
	Engine.drop()
	Engine.localRoot = nil
end)
if LocalPlayer.Character then onLocalChar(LocalPlayer.Character) end

-- 7 ===================== OVERLAY (visuals) ========================
local O = {}

O.fov = New("Frame", {
	Name = "Fov", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), BackgroundTransparency = 1,
	BorderSizePixel = 0, Visible = false, Size = UDim2.fromOffset(300, 300),
}, overlay)
Round(O.fov)
O.fovStroke = Stroke(O.fov, T.text, 1.5, 0.35)

O.fovHandle = New("TextButton", {
	Name = "FovHandle", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(26, 26), Text = "", AutoButtonColor = false,
	BackgroundColor3 = T.bg, Visible = false,
}, hudLayer)
Round(O.fovHandle)
O.fovHandleStroke = Stroke(O.fovHandle, T.text, 2, 0.1)
New("UIPadding", {}, O.fovHandle)

O.xhRoot = New("Frame", {
	Name = "Crosshair", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(0, 0),
	BackgroundTransparency = 1, Visible = false,
}, overlay)
O.xhBars = {}
for i = 1, 4 do
	O.xhBars[i] = New("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BorderSizePixel = 0, BackgroundColor3 = T.text }, O.xhRoot)
end
O.xhDot = New("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BorderSizePixel = 0, BackgroundColor3 = T.text }, O.xhRoot)
Round(O.xhDot)
O.xhRing = New("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, BorderSizePixel = 0 }, O.xhRoot)
Round(O.xhRing)
O.xhRingStroke = Stroke(O.xhRing, T.text, 2, 0)

O.ind = New("Frame", {
	Name = "Indicator", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(22, 22), Rotation = 45,
	BackgroundTransparency = 1, BorderSizePixel = 0, Visible = false,
}, overlay)
Corner(O.ind, 3)
O.indStroke = Stroke(O.ind, T.good, 2, 0)

O.snap = New("Frame", {
	Name = "Snapline", AnchorPoint = Vector2.new(0.5, 0.5), BorderSizePixel = 0, Size = UDim2.fromOffset(0, 2),
	BackgroundColor3 = T.text, BackgroundTransparency = 0.35, Visible = false,
}, overlay)

O.lead = New("Frame", {
	Name = "Lead", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(8, 8), BackgroundColor3 = T.warn,
	BorderSizePixel = 0, Visible = false,
}, overlay)
Round(O.lead)

O.ghost = New("Frame", {
	Name = "Wallmark", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(18, 18), Rotation = 45,
	BackgroundTransparency = 1, BorderSizePixel = 0, Visible = false,
}, overlay)
Corner(O.ghost, 3)
O.ghostStroke = Stroke(O.ghost, T.dim, 1.5, 0.3)

O.vignette = New("Frame", {
	Name = "Vignette", Size = UDim2.fromScale(1, 1), BackgroundColor3 = T.bad, BackgroundTransparency = 1, Visible = false,
}, overlay)

O.elev = New("Frame", {
	Name = "Elevation", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(14, 14), Rotation = 45,
	BackgroundTransparency = 1, BorderSizePixel = 0, Visible = false,
}, overlay)
O.elevStroke = Stroke(O.elev, T.warn, 2, 0)

O.flash = New("Frame", {
	Name = "FireFlash", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(255, 200, 200),
	BackgroundTransparency = 1, Visible = false,
}, overlay)
O.info = New("Frame", {
	Name = "Info", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -78), Size = UDim2.fromOffset(230, 56),
	BackgroundColor3 = T.card, BackgroundTransparency = 0.08, BorderSizePixel = 0, Visible = false,
}, overlay)
Corner(O.info, 12)
O.infoStroke = Stroke(O.info, T.line, 1, 0)
O.infoAccent = New("Frame", { BorderSizePixel = 0, Size = UDim2.new(0, 3, 1, -16), Position = UDim2.new(0, 8, 0, 8), BackgroundColor3 = T.good }, O.info)
Round(O.infoAccent)
O.infoName = Label(O.info, "", 14, T.text, { Font = Enum.Font.GothamBold, Position = UDim2.new(0, 20, 0, 8), Size = UDim2.new(1, -30, 0, 18), TextTruncate = Enum.TextTruncate.AtEnd })
O.infoMeta = Label(O.info, "", 11, T.dim, { Position = UDim2.new(0, 20, 0, 28), Size = UDim2.new(1, -30, 0, 14), Font = Enum.Font.RobotoMono })
O.infoBar = New("Frame", { BorderSizePixel = 0, Position = UDim2.new(0, 20, 1, -11), Size = UDim2.new(1, -34, 0, 4), BackgroundColor3 = T.off }, O.info)
Round(O.infoBar)
O.infoFill = New("Frame", { BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), BackgroundColor3 = T.good }, O.infoBar)
Round(O.infoFill)

O.hud = Label(hudLayer, "", 11, T.text, {
	Name = "Hud", Font = Enum.Font.RobotoMono, Position = UDim2.new(0, 14, 0, 10), Size = UDim2.fromOffset(190, 44),
	TextYAlignment = Enum.TextYAlignment.Top, Visible = false, BackgroundTransparency = 1,
})

local Overlay = {}
local lastR = -1
local function setFovSize(r)
	if math.abs(r - lastR) < 0.25 then return end
	lastR = r
	O.fov.Size = UDim2.fromOffset(r * 2, r * 2)
	O.fovHandle.Position = UDim2.new(0.5, r, 0.5, 0)
end

function Overlay.hideTarget()
	O.ind.Visible = false
	O.snap.Visible = false
	O.info.Visible = false
	O.lead.Visible = false
	O.elev.Visible = false
end

function Overlay.render(dt)
	setFovSize(Engine.fovCurrent)
	if cfg.selfHpWarn then
		local char = LocalPlayer.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hum and hum.Health > 0 and hum.Health / math.max(hum.MaxHealth, 1) <= cfg.selfHpThreshold / 100 then
			O.vignette.Visible = true
			O.vignette.BackgroundTransparency = 0.82 + 0.1 * math.sin(os.clock() * 4)
		else
			O.vignette.Visible = false
		end
	else
		O.vignette.Visible = false
	end
	local sinceFire = os.clock() - Engine.fireFlashAt
	if cfg.fireFlash and sinceFire < 0.15 then
		O.flash.Visible = true
		O.flash.BackgroundTransparency = 0.88 + 0.1 * (sinceFire / 0.15)
	else
		O.flash.Visible = false
	end
	if cfg.fovPulse and O.fov.Visible and not Engine.locked then
		local pulse = 0.5 + 0.5 * math.sin(os.clock() * 3)
		O.fovStroke.Transparency = math.clamp(cfg.fovTransparency + pulse * 0.25, 0, 1)
	elseif O.fov.Visible then
		O.fovStroke.Transparency = cfg.fovTransparency
	end
	if cfg.wallmark and Engine.ghost then -- fades out over Wallmark Fade seconds, independent of whether a target is currently visible
		local age = os.clock() - Engine.ghost.t
		if age < cfg.wallmarkFade then
			O.ghost.Visible = true
			O.ghost.Position = UDim2.fromOffset(Engine.ghost.x, Engine.ghost.y)
			O.ghostStroke.Transparency = 0.3 + 0.7 * (age / cfg.wallmarkFade)
		else
			O.ghost.Visible = false
			Engine.ghost = nil
		end
	else
		O.ghost.Visible = false
	end

	local c = Engine.out.c
	if not c then
		Overlay.hideTarget()
		return
	end
	local col
	if cfg.colorBlind then
		col = Engine.locked and Color3.fromRGB(255, 170, 0) or Color3.fromRGB(0, 160, 255)
	else
		col = ACCENTS[Engine.locked and cfg.lockColor or cfg.targetColor]
	end
	local glow = cfg.glowIntensity
	if cfg.elevationArrow then
		local vp = gui.AbsoluteSize
		local cyMid = vp.Y * 0.5
		local dy = c.sy - cyMid
		if math.abs(dy) > Engine.fovCurrent * 0.55 then
			O.elev.Visible = true
			O.elev.Position = UDim2.fromOffset(c.sx, cyMid + (dy > 0 and 1 or -1) * Engine.fovCurrent * 0.9)
			O.elevStroke.Color = col
		else
			O.elev.Visible = false
		end
	else
		O.elev.Visible = false
	end
	if cfg.showIndicator then
		O.ind.Visible = true
		O.ind.Position = UDim2.fromOffset(c.sx, c.sy)
		setIf(O.indStroke, "Color", col)
		O.indStroke.Thickness = 2 * glow
	else
		O.ind.Visible = false
	end
	if cfg.showSnapline then
		local vp = gui.AbsoluteSize
		local fx, fy = vp.X * 0.5, vp.Y
		local dx, dy = c.sx - fx, c.sy - fy
		O.snap.Visible = true
		O.snap.Position = UDim2.fromOffset((fx + c.sx) * 0.5, (fy + c.sy) * 0.5)
		O.snap.Size = UDim2.fromOffset(math.sqrt(dx * dx + dy * dy), math.max(1, 2 * glow))
		O.snap.Rotation = math.deg(math.atan2(dy, dx))
		setIf(O.snap, "BackgroundColor3", col)
	else
		O.snap.Visible = false
	end
	if cfg.showLead and Engine.locked and Engine.leadOn then
		O.lead.Visible = true
		O.lead.Position = UDim2.fromOffset(Engine.leadX, Engine.leadY)
	else
		O.lead.Visible = false
	end
	if cfg.showInfo then
		O.info.Visible = true
		local e = c.e
		setIf(O.infoName, "Text", e.player and e.player.DisplayName or e.model.Name)
		setIf(O.infoAccent, "BackgroundColor3", col)
		local frac = math.clamp(c.hp / math.max(c.maxHp, 1), 0, 1)
		local meta = ""
		if cfg.showHealth then meta = ("HP %d"):format(math.floor(c.hp + 0.5)) end
		if cfg.showDistance then
			local distText = cfg.distanceUnit == "Meters" and ("%dm"):format(math.floor(c.wd * 0.28 + 0.5)) or ("%d st"):format(math.floor(c.wd + 0.5))
			meta = meta .. (meta ~= "" and "   " or "") .. distText
		end
		if cfg.showMeter and Engine.locked then
			meta = meta .. (meta ~= "" and "   " or "") .. ("ON %d%%"):format(math.floor(Engine.meter * 100 + 0.5))
		end
		if cfg.debugReadout and Engine.locked then
			meta = meta .. "\n" .. ("ANG %.1f  ALPHA %.2f  LEAD %.2f"):format(Engine.lastAngle, Engine.lastAlpha, Engine.lastLead)
		end
		if cfg.teamDebug and c.teamInfo then
			meta = meta .. "\n" .. c.teamInfo
		end
		setIf(O.infoMeta, "Text", meta)
		if cfg.showHealth then
			O.infoFill.Size = UDim2.fromScale(frac, 1)
			setIf(O.infoFill, "BackgroundColor3", Color3.fromHSV(frac * 0.33, 0.75, 1))
		end
	else
		O.info.Visible = false
	end
end

-- 8 ===================== MENU =====================================
local Refresh = {}
local setCfg, onChanged, applyAll, refreshControls, Unload, setPanic, step, guardedStep

local Drag = { input = nil, fn = nil, done = nil }
function Drag.stop()
	local d = Drag.done
	Drag.input, Drag.fn, Drag.done = nil, nil, nil
	if d then d() end
end
function Drag.start(input, fn, done)
	Drag.stop()
	Drag.input, Drag.fn, Drag.done = input, fn, done
end

local function commitPos(obj, kx, ky)
	local vp = gui.AbsoluteSize
	local c = obj.AbsolutePosition + obj.AbsoluteSize * 0.5
	layout[kx] = math.clamp(c.X / math.max(vp.X, 1), 0.02, 0.98)
	layout[ky] = math.clamp(c.Y / math.max(vp.Y, 1), 0.02, 0.98)
	obj.Position = UDim2.fromScale(layout[kx], layout[ky])
end

-- drag `target` by its `handle`; a press that barely moves is a click
local function makeMovable(handle, target, canDrag, onClick, onMoved)
	handle.InputBegan:Connect(function(input)
		if not isPointer(input) then return end
		if canDrag and not canDrag() then return end
		local startPos, startIn, moved = target.Position, input.Position, false
		Drag.start(input, function(p)
			local d = p - startIn
			if not moved and d.Magnitude > 8 then moved = true end
			if moved then
				target.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
			end
		end, function()
			if moved then
				if onMoved then onMoved() end
			elseif onClick then
				onClick()
			end
		end)
	end)
end

-- window shell
local win = New("Frame", {
	Name = "Window", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(560, 340),
	BackgroundColor3 = T.bg, BorderSizePixel = 0,
}, menuLayer)
Corner(win, 16)
local winRim = Stroke(win, T.line, 1.4, 0.1)
local winRimGrad = New("UIGradient", {
	Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(0.5, 0), NumberSequenceKeypoint.new(1, 0.55),
	}),
}, winRim)
Accent.sub(function()
	winRimGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, T.line), ColorSequenceKeypoint.new(0.5, Accent.color), ColorSequenceKeypoint.new(1, T.line),
	})
end)
local winScale = New("UIScale", { Scale = 1 }, win)

-- fine cracks across the glass: a handful of thin, irregular lines fanning from one corner
local crackLayer = New("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ClipsDescendants = true, ZIndex = 3 }, win)
local CRACKS = {
	{ x = 0.04, y = 0.06, len = 130, rot = 52, w = 1 },
	{ x = 0.06, y = 0.09, len = 80, rot = 18, w = 1 },
	{ x = 0.1, y = 0.05, len = 60, rot = -30, w = 1 },
	{ x = 0.97, y = 0.92, len = 150, rot = -128, w = 1 },
	{ x = 0.95, y = 0.88, len = 70, rot = -162, w = 1 },
	{ x = 0.5, y = 1.0, len = 90, rot = -80, w = 1 },
}
local crackLines = {}
for _, c in ipairs(CRACKS) do
	local line = New("Frame", {
		BackgroundColor3 = T.text, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(c.x, c.y), Size = UDim2.fromOffset(c.len, c.w), Rotation = c.rot,
		BackgroundTransparency = 0.85,
	}, crackLayer)
	crackLines[#crackLines + 1] = line
end

-- jagged red tendril streaks near the top-right corner, tapering out to nothing
local tendrilLayer = New("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ClipsDescendants = true, ZIndex = 3 }, win)
for i, spec in ipairs({ { rot = -24, len = 170, y = 0.1 }, { rot = -8, len = 130, y = 0.22 }, { rot = -40, len = 95, y = 0.04 } }) do
	local streak = New("Frame", {
		BackgroundColor3 = Accent.color, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 6, spec.y, 0), Size = UDim2.fromOffset(spec.len, 3), Rotation = spec.rot,
	}, tendrilLayer)
	Round(streak)
	New("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 1) }) }, streak)
	Accent.sub(function() streak.BackgroundColor3 = Accent.color end)
end

-- a soft diagonal shine that sweeps across the window once every few seconds, for a glassy, expensive feel
local shineClip = New("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ClipsDescendants = true, ZIndex = 50 }, win)
local shine = New("Frame", {
	BackgroundColor3 = Color3.fromRGB(255, 210, 210), BorderSizePixel = 0, Rotation = 18,
	AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(-0.3, 0.5), Size = UDim2.fromOffset(70, 700),
}, shineClip)
New("UIGradient", {
	Rotation = 90,
	Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0.88), NumberSequenceKeypoint.new(1, 1),
	}),
}, shine)
task.spawn(function()
	while App.alive do
		if not cfg.liteUI then startShine() end
		task.wait(5)
	end
end)

local function layoutWindow()
	local vp = gui.AbsoluteSize
	if vp.X < 50 then
		local cam = Workspace.CurrentCamera
		vp = cam and cam.ViewportSize or Vector2.new(800, 400)
	end
	win.Size = UDim2.fromOffset(math.clamp(vp.X - 24, 300, 640), math.clamp(vp.Y - 24, 230, 400))
end

-- a small glowing "eye" glyph: a dark socket, a glowing iris ring, a bright pupil, and a thin scar
local function eyeGlyph(parent, size, position, anchor)
	local holder = New("Frame", {
		BackgroundTransparency = 1, Position = position, AnchorPoint = anchor or Vector2.new(0, 0.5), Size = UDim2.fromOffset(size, size),
	}, parent)
	local socket = New("Frame", { BackgroundColor3 = Color3.fromRGB(3, 2, 2), Size = UDim2.fromScale(1, 1) }, holder)
	Round(socket)
	local ring = New("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.86, 0.86) }, holder)
	Round(ring)
	local ringStroke = Stroke(ring, Accent.color, 2, 0)
	local halo = New("Frame", { BackgroundColor3 = Accent.color, BackgroundTransparency = 0.55, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.46, 0.46) }, holder)
	Round(halo)
	local pupil = New("Frame", { BackgroundColor3 = Accent.color, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(math.max(3, size * 0.16), math.max(3, size * 0.16)) }, holder)
	Round(pupil)
	New("Frame", {
		BackgroundColor3 = T.text, BackgroundTransparency = 0.6, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(size * 0.9, 1), Rotation = 25,
	}, holder)
	return holder, ringStroke, halo, pupil
end

-- title bar
local titleBar = New("Frame", { Name = "TitleBar", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 46), Active = true }, win)
local markHolder, markRingStroke, markHalo, markPupil = eyeGlyph(titleBar, 22, UDim2.new(0, 16, 0.5, 0))
Accent.sub(function()
	markRingStroke.Color = Accent.color
	markHalo.BackgroundColor3 = Accent.color
	markPupil.BackgroundColor3 = Accent.color
end)
local seenLockFlash, seenPanic = Engine.lockFlashAt, false
local function constrictEye(halo, pupil)
	local haloSize, pupilSize = halo.Size, pupil.Size
	Tw(halo, { Size = UDim2.fromScale(0.3, 0.3) }, 0.08)
	Tw(pupil, { Size = UDim2.fromOffset(9, 9) }, 0.08)
	task.delay(0.1, function()
		if App.alive then
			Tw(halo, { Size = haloSize }, 0.22, Enum.EasingStyle.Back)
			Tw(pupil, { Size = pupilSize }, 0.22, Enum.EasingStyle.Back)
		end
	end)
end
crackLayer.Visible = not cfg.liteUI
tendrilLayer.Visible = not cfg.liteUI
Janitor.connect(RunService.Heartbeat, function()
	crackLayer.Visible = not cfg.liteUI
	tendrilLayer.Visible = not cfg.liteUI
	if Engine.lockFlashAt ~= seenLockFlash then
		seenLockFlash = Engine.lockFlashAt
		if not cfg.liteUI then
			constrictEye(markHalo, markPupil)
			constrictEye(fmHalo, fmDot)
			for _, line in ipairs(crackLines) do
				Tw(line, { BackgroundTransparency = 0.25 }, 0.05)
				task.delay(0.08, function()
					if App.alive then Tw(line, { BackgroundTransparency = 0.85 }, 0.5) end
				end)
			end
		end
	end
	if App.panic ~= seenPanic then
		seenPanic = App.panic
		if App.panic and not cfg.liteUI then
			O.vignette.Visible = true
			O.vignette.BackgroundTransparency = 0.55
			Tw(O.vignette, { BackgroundTransparency = 1 }, 0.6)
		end
	end
	if cfg.liteUI then return end
	local now = os.clock()
	winRimGrad.Rotation = (now * 22) % 360
	local breathe = 0.5 + 0.5 * math.sin(now * 1.6)
	markRingStroke.Transparency = 0.5 * breathe
	markHalo.BackgroundTransparency = 0.4 + 0.3 * breathe
end)

-- a few red embers drift slowly up through the window, for atmosphere
for i = 1, 5 do
	local ember = New("Frame", {
		BackgroundColor3 = Accent.color, BorderSizePixel = 0, Size = UDim2.fromOffset(3, 3),
		Position = UDim2.fromScale(0.08 + (i - 1) * 0.21, 1.05), BackgroundTransparency = 1, ZIndex = 2,
	}, win)
	Round(ember)
	Accent.sub(function() ember.BackgroundColor3 = Accent.color end)
	task.spawn(function()
		task.wait(i * 0.7)
		while App.alive do
			if cfg.liteUI then
				task.wait(1)
			else
				ember.Position = UDim2.fromScale(ember.Position.X.Scale, 1.05)
				ember.BackgroundTransparency = 1
				local dur = 3.5 + math.random() * 2
				Tw(ember, { Position = UDim2.fromScale(ember.Position.X.Scale + (math.random() - 0.5) * 0.08, -0.08), BackgroundTransparency = 0.5 }, dur * 0.15)
				task.wait(dur * 0.15)
				Tw(ember, { BackgroundTransparency = 1 }, dur * 0.85)
				task.wait(dur * 0.85 + math.random() * 1.5)
			end
		end
	end)
end
local titleGhost = Label(titleBar, NAME, 15, Accent.color, {
	Font = Enum.Font.GothamBlack, Position = UDim2.new(0, 48, 0, 1), Size = UDim2.new(0, 96, 1, 0), TextTransparency = 0.55,
})
Accent.sub(function() titleGhost.TextColor3 = Accent.color end)
Label(titleBar, NAME, 15, T.text, { Font = Enum.Font.GothamBlack, Position = UDim2.new(0, 46, 0, 0), Size = UDim2.new(0, 96, 1, 0) })
local nextGlitch = 0
Janitor.connect(RunService.Heartbeat, function()
	if cfg.liteUI then return end
	local now = os.clock()
	if now < nextGlitch then return end
	nextGlitch = now + 1.4 + math.random() * 2.2
	local jx, jy = math.random(-3, 3), math.random(-1, 1)
	titleGhost.Position = UDim2.new(0, 48 + jx, 0, 1 + jy)
	task.delay(0.06, function()
		if App.alive then titleGhost.Position = UDim2.new(0, 48, 0, 1) end
	end)
end)
local verChip = New("Frame", { BackgroundColor3 = T.cardHi, BorderSizePixel = 0, Position = UDim2.new(0, 132, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), Size = UDim2.fromOffset(44, 18) }, titleBar)
Round(verChip)
Label(verChip, VERSION, 10, T.dim, { Font = Enum.Font.GothamBold, Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center })

local statusChip = New("Frame", {
	BackgroundColor3 = T.card, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -118, 0.5, 0), Size = UDim2.fromOffset(86, 24),
}, titleBar)
Round(statusChip)
Stroke(statusChip, T.line, 1, 0)
local statusDot = New("Frame", { BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 10, 0.5, 0), Size = UDim2.fromOffset(7, 7), BackgroundColor3 = T.dim }, statusChip)
Round(statusDot)
local statusLabel = Label(statusChip, "OFF", 10, T.dim, { Font = Enum.Font.GothamBold, Position = UDim2.new(0, 24, 0, 0), Size = UDim2.new(1, -28, 1, 0) })
local lastStatus
local function setStatus(text, color)
	if lastStatus == text then return end
	lastStatus = text
	statusLabel.Text, statusLabel.TextColor3, statusDot.BackgroundColor3 = text, color, color
end

local function titleBtn(text, color, xr)
	local b = New("TextButton", {
		Text = text, Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = color, BackgroundColor3 = T.card, AutoButtonColor = false,
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, xr, 0.5, 0), Size = UDim2.fromOffset(28, 28), BorderSizePixel = 0,
	}, titleBar)
	Corner(b, 9)
	local st = Stroke(b, T.line, 1, 0)
	return b, st
end
local closeBtn, closeStroke = titleBtn("X", T.dim, -14)
local minBtn = titleBtn("-", T.dim, -48)
local panicTitleBtn = titleBtn("!", T.bad, -82)

-- a jagged cracked-glass divider instead of one plain straight line
local dividerHolder = New("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0, 16, 0, 42), Size = UDim2.new(1, -32, 0, 8) }, win)
local DIVIDER_JAG = { 0, -2, 1, -1, 2, 0, -1 }
local dividerSegs = {}
for i = 1, #DIVIDER_JAG do
	local frac0, frac1 = (i - 1) / #DIVIDER_JAG, i / #DIVIDER_JAG
	local seg = New("Frame", {
		BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5), BackgroundColor3 = Color3.new(1, 1, 1),
		Position = UDim2.new(frac0, 0, 0.5, DIVIDER_JAG[i]),
		Size = UDim2.new(frac1 - frac0, 2, 0, 1),
	}, dividerHolder)
	local edgeFade = 1 - math.abs(0.5 - (frac0 + frac1) / 2) * 1.4
	New("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, math.clamp(1 - edgeFade, 0, 1)), NumberSequenceKeypoint.new(1, 0.3) }) }, seg)
	dividerSegs[#dividerSegs + 1] = seg
end
Accent.sub(function()
	for _, seg in ipairs(dividerSegs) do seg.BackgroundColor3 = Accent.color end
end)

-- sidebar
local side = New("Frame", { Name = "Side", BackgroundColor3 = T.side, BorderSizePixel = 0, Position = UDim2.new(0, 10, 0, 56), Size = UDim2.new(0, 112, 1, -66) }, win)
Corner(side, 12)
Stroke(side, T.line, 1, 0)
local TAB_STEP, TAB_H = 38, 32
local tabScroll = New("ScrollingFrame", {
	BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ScrollBarThickness = 0,
	CanvasSize = UDim2.fromOffset(0, 12 + #TABS * TAB_STEP), ScrollingDirection = Enum.ScrollingDirection.Y,
}, side)
local selector = New("Frame", { BorderSizePixel = 0, Position = UDim2.new(0, 6, 0, 6), Size = UDim2.new(1, -12, 0, TAB_H), BackgroundColor3 = Accent.color, BackgroundTransparency = 0.86 }, tabScroll)
Corner(selector, 9)
local selectorBar = New("Frame", {
	BorderSizePixel = 0, Position = UDim2.new(0, -1, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5),
	Size = UDim2.new(0, 3, 0, 20), Rotation = 4, BackgroundColor3 = Accent.color,
}, selector)
Corner(selectorBar, 2)
Accent.sub(function()
	selector.BackgroundColor3 = Accent.color
	selectorBar.BackgroundColor3 = Accent.color
end)

local body = New("Frame", { Name = "Body", BackgroundTransparency = 1, Position = UDim2.new(0, 132, 0, 56), Size = UDim2.new(1, -142, 1, -66) }, win)
local pages, pageOrder, built, tabButtons = {}, {}, {}, {}
local currentTab

local function nextOrder(page)
	pageOrder[page] = (pageOrder[page] or 0) + 1
	return pageOrder[page]
end

-- controls ---------------------------------------------------------
local function Row(page, h)
	local f = New("Frame", { BackgroundColor3 = T.card, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, h), LayoutOrder = nextOrder(page) }, page)
	Corner(f, 12)
	Stroke(f, T.line, 1, 0)
	local crackClip = New("Frame", { BackgroundTransparency = 1, ClipsDescendants = true, ZIndex = 0, Size = UDim2.fromScale(1, 1) }, f)
	local crack = New("Frame", {
		BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Rotation = 24,
		AnchorPoint = Vector2.new(0, 0), Position = UDim2.new(0, 2, 0, 2), Size = UDim2.fromOffset(2, 40),
	}, crackClip)
	New("UIGradient", { Rotation = 90, Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0.88), NumberSequenceKeypoint.new(1, 1) }) }, crack)
	return f
end

local function addHeader(page, text)
	local f = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26), LayoutOrder = nextOrder(page) }, page)
	local tick = New("Frame", { BorderSizePixel = 0, Position = UDim2.new(0, 4, 0.5, 2), AnchorPoint = Vector2.new(0, 0.5), Size = UDim2.fromOffset(10, 2), BackgroundColor3 = Accent.color }, f)
	local function paint(inst, prop) -- keep a property on the accent color
		Accent.sub(function() inst[prop] = Accent.color end)
	end

	paint(tick, "BackgroundColor3")
	Label(f, string.upper(text), 10, T.dim, { Font = Enum.Font.GothamBold, Position = UDim2.new(0, 20, 0, 0), Size = UDim2.new(1, -24, 1, 4) })
end

local function addNote(page, text, color)
	local row = Row(page, 40)
	Label(row, text, 11, color or T.dim, { Position = UDim2.new(0, 14, 0, 0), Size = UDim2.new(1, -28, 1, 0), TextWrapped = true })
	return row
end

local function addButton(page, text, kind, fn)
	local color = kind == "danger" and T.bad or (kind == "ghost" and T.text or nil)
	local b = New("TextButton", {
		Text = text, Font = Enum.Font.GothamBold, TextSize = 13, AutoButtonColor = false, BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 40), LayoutOrder = nextOrder(page), ClipsDescendants = true,
		BackgroundColor3 = kind == "primary" and Accent.color or T.card, TextColor3 = kind == "primary" and T.bg or color,
	}, page)
	Corner(b, 12)
	local st = Stroke(b, kind == "danger" and T.bad or T.line, 1, kind == "danger" and 0.5 or 0)
	if kind == "primary" then
		Accent.sub(function() b.BackgroundColor3 = Accent.color end)
	end
	b.Activated:Connect(function()
		Tw(b, { BackgroundTransparency = 0.35 }, nil)
		Tw(b, { BackgroundTransparency = 0 }, 0.25)
		fn()
	end)
	return b
end

-- generic chip row. get() -> current, pick(v) applies. key lets setCfg refresh it.
local function addChoice(page, label, opts, get, pick, perRow, key)
	perRow = perRow or (#opts <= 4 and #opts or 3)
	local rows = math.ceil(#opts / perRow)
	local row = Row(page, 42 + rows * 36)
	Label(row, label, 14, T.text, { Position = UDim2.new(0, 14, 0, 8), Size = UDim2.new(1, -28, 0, 20) })
	local strip = New("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0, 12, 0, 36), Size = UDim2.new(1, -24, 0, rows * 36 - 6) }, row)
	New("UIGridLayout", {
		CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder,
		CellSize = UDim2.new(1 / perRow, -math.ceil(6 * (perRow - 1) / perRow), 0, 30),
	}, strip)
	local chips = {}
	local function render()
		local cur = get()
		for name, chip in pairs(chips) do
			local on = name == cur
			Tw(chip, { BackgroundColor3 = on and Accent.color or T.cardHi, TextColor3 = on and T.bg or T.text }, 0.15)
		end
	end
	for i, name in ipairs(opts) do
		local chip = New("TextButton", {
			Text = name, Font = Enum.Font.GothamBold, TextSize = 12, AutoButtonColor = false, BorderSizePixel = 0,
			LayoutOrder = i, BackgroundColor3 = T.cardHi, TextColor3 = T.text, ClipsDescendants = true,
		}, strip)
		Corner(chip, 9)
		chip.Activated:Connect(function()
			pick(name)
			render()
		end)
		chips[name] = chip
	end
	if key then Refresh[key] = render end
	Accent.sub(render)
end

local function buildSchema(page, tab)
	local function addToggle(page, e)
		local row = Row(page, e.desc and 56 or 46)
		Label(row, e.label, 14, T.text, { Position = UDim2.new(0, 14, 0, e.desc and 9 or 0), Size = UDim2.new(1, -84, 0, e.desc and 20 or 46) })
		if e.desc then
			Label(row, e.desc, 11, T.dim, { Position = UDim2.new(0, 14, 0, 30), Size = UDim2.new(1, -84, 0, 16) })
		end
		local sw = New("TextButton", {
			Text = "", AutoButtonColor = false, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -14, 0.5, 0),
			Size = UDim2.fromOffset(46, 26), BackgroundColor3 = T.off, BorderSizePixel = 0,
		}, row)
		Round(sw)
		local knob = New("Frame", { AnchorPoint = Vector2.new(0, 0.5), Size = UDim2.fromOffset(20, 20), BackgroundColor3 = T.text, BorderSizePixel = 0, Position = UDim2.new(0, 3, 0.5, 0) }, sw)
		Round(knob)
		local function render()
			local on = cfg[e.key]
			Tw(sw, { BackgroundColor3 = on and Accent.color or T.off }, 0.15)
			Tw(knob, { Position = on and UDim2.new(1, -23, 0.5, 0) or UDim2.new(0, 3, 0.5, 0) }, 0.15)
		end
		sw.Activated:Connect(function() setCfg(e.key, not cfg[e.key]) end)
		Refresh[e.key] = render
		Accent.sub(render)
	end

	local function fmtValue(e, v)
		if e.zero and v == 0 then return e.zero end
		return string.format(e.fmt, v)
	end

	local function addSlider(page, e)
		local row = Row(page, 76)
		Label(row, e.label, 14, T.text, { Position = UDim2.new(0, 14, 0, 8), Size = UDim2.new(0.55, 0, 0, 20) })
		local readout = New("TextButton", {
			BackgroundColor3 = T.cardHi, BorderSizePixel = 0, AutoButtonColor = false, Font = Enum.Font.RobotoMono, TextSize = 11,
			TextColor3 = T.text, Text = "", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 8), Size = UDim2.fromOffset(86, 22),
		}, row)
		Corner(readout, 8)
		local function stepBtn(sym, pos)
			local b = New("TextButton", {
				Text = sym, Font = Enum.Font.GothamBold, TextSize = 16, TextColor3 = T.text, BackgroundColor3 = T.cardHi,
				AutoButtonColor = false, BorderSizePixel = 0, Position = pos, Size = UDim2.fromOffset(30, 28),
			}, row)
			Corner(b, 9)
			return b
		end
		local minus = stepBtn("-", UDim2.new(0, 10, 0, 38))
		local plus = stepBtn("+", UDim2.new(1, -40, 0, 38))
		local track = New("Frame", { BackgroundColor3 = T.off, BorderSizePixel = 0, Position = UDim2.new(0, 50, 0, 50), Size = UDim2.new(1, -100, 0, 6) }, row)
		Round(track)
		local fill = New("Frame", { BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), BackgroundColor3 = Accent.color }, track)
		Round(fill)
		local knob = New("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(20, 20), BackgroundColor3 = T.text, BorderSizePixel = 0, ZIndex = 2 }, track)
		Round(knob)
		local knobStroke = Stroke(knob, Accent.color, 2, 0)
		local hit = New("TextButton", { Text = "", BackgroundTransparency = 1, Position = UDim2.new(0, -14, 0, -16), Size = UDim2.new(1, 28, 0, 38), ZIndex = 3 }, track)

		local function render()
			local v = cfg[e.key]
			local f = (v - e.min) / (e.max - e.min)
			fill.Size = UDim2.fromScale(f, 1)
			knob.Position = UDim2.fromScale(f, 0.5)
			readout.Text = fmtValue(e, v)
		end
		local function commit(v)
			v = math.clamp(math.floor((v - e.min) / e.step + 0.5) * e.step + e.min, e.min, e.max)
			if v ~= cfg[e.key] then setCfg(e.key, v) end
		end
		local function follow(x)
			local f = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
			commit(e.min + (e.max - e.min) * f)
		end
		hit.InputBegan:Connect(function(input)
			if not isPointer(input) then return end
			page.ScrollingEnabled = false -- keep the page from scrolling while the slider moves
			follow(input.Position.X)
			Drag.start(input, function(p) follow(p.X) end, function() page.ScrollingEnabled = true end)
		end)
		minus.Activated:Connect(function() commit(cfg[e.key] - e.step) end)
		plus.Activated:Connect(function() commit(cfg[e.key] + e.step) end)
		readout.Activated:Connect(function() setCfg(e.key, e.def) end) -- tap the value to reset it
		Refresh[e.key] = render
		Accent.sub(function()
			fill.BackgroundColor3 = Accent.color
			knobStroke.Color = Accent.color
		end)
		render()
	end

	local function addColor(page, e)
		local row = Row(page, 56)
		Label(row, e.label, 14, T.text, { Position = UDim2.new(0, 14, 0, 0), Size = UDim2.new(0.4, 0, 1, 0) })
		local holder = New("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.fromOffset(#e.opts * 30, 28) }, row)
		New("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, holder)
		local dots = {}
		local function render()
			for name, d in pairs(dots) do
				local on = cfg[e.key] == name
				d.stroke.Transparency = on and 0 or 1
				d.btn.Size = UDim2.fromOffset(on and 26 or 22, on and 26 or 22)
			end
		end
		for i, name in ipairs(e.opts) do
			local slotFrame = New("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(26, 28), LayoutOrder = i }, holder)
			local btn = New("TextButton", {
				Text = "", AutoButtonColor = false, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(22, 22), BackgroundColor3 = ACCENTS[name],
			}, slotFrame)
			Round(btn)
			local st = Stroke(btn, T.text, 2, 1)
			btn.Activated:Connect(function() setCfg(e.key, name) end)
			dots[name] = { btn = btn, stroke = st }
		end
		Refresh[e.key] = render
		render()
	end

	local function addKey(page, e)
		local row = Row(page, e.desc and 56 or 46)
		Label(row, e.label, 14, T.text, { Position = UDim2.new(0, 14, 0, e.desc and 9 or 0), Size = UDim2.new(1, -140, 0, e.desc and 20 or 46) })
		if e.desc then
			Label(row, e.desc, 11, T.dim, { Position = UDim2.new(0, 14, 0, 30), Size = UDim2.new(1, -140, 0, 16) })
		end
		local b = New("TextButton", {
			Font = Enum.Font.RobotoMono, TextSize = 11, AutoButtonColor = false, BorderSizePixel = 0, Text = "",
			BackgroundColor3 = T.cardHi, TextColor3 = T.text, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.fromOffset(112, 30),
		}, row)
		Corner(b, 9)
		local bst = Stroke(b, T.line, 1, 0)
		local function render()
			if App.listening and App.listening.btn == b then
				b.Text = "PRESS A KEY"
				bst.Color = Accent.color
			else
				b.Text = string.upper(cfg[e.key])
				bst.Color = T.line
			end
		end
		b.Activated:Connect(function()
			if App.listening then
				App.listening.cancel()
			end
			App.listening = {
				btn = b,
				cb = function(name)
					setCfg(e.key, name)
					render()
				end,
				cancel = function()
					App.listening = nil
					render()
				end,
			}
			render()
		end)
		Refresh[e.key] = render
		Accent.sub(render)
	end

	local function addTextInput(page, e)
		local row = Row(page, e.desc and 56 or 46)
		Label(row, e.label, 14, T.text, { Position = UDim2.new(0, 14, 0, e.desc and 9 or 0), Size = UDim2.new(1, -150, 0, e.desc and 20 or 46) })
		if e.desc then
			Label(row, e.desc, 11, T.dim, { Position = UDim2.new(0, 14, 0, 30), Size = UDim2.new(1, -150, 0, 16) })
		end
		local box = New("TextBox", {
			Font = Enum.Font.RobotoMono, TextSize = 12, BorderSizePixel = 0, Text = cfg[e.key], PlaceholderText = "name",
			PlaceholderColor3 = T.dim, BackgroundColor3 = T.cardHi, TextColor3 = T.text, ClearTextOnFocus = false,
			AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.fromOffset(118, 30),
		}, row)
		Corner(box, 9)
		local bst = Stroke(box, T.line, 1, 0)
		box.Focused:Connect(function() bst.Color = Accent.color end)
		box.FocusLost:Connect(function(enterPressed)
			bst.Color = T.line
			setCfg(e.key, box.Text)
		end)
		Refresh[e.key] = function()
			if not box:IsFocused() then box.Text = cfg[e.key] end
		end
		Accent.sub(function() if box:IsFocused() then bst.Color = Accent.color end end)
	end

	for _, e in ipairs(SCHEMA) do
		if e.tab == tab then
			local k = e.kind
			if k == "header" then
				addHeader(page, e.label)
			elseif k == "bool" then
				addToggle(page, e)
			elseif k == "num" then
				addSlider(page, e)
			elseif k == "enum" then
				addChoice(page, e.label, e.opts, function() return cfg[e.key] end, function(v) setCfg(e.key, v) end, e.perRow, e.key)
			elseif k == "color" then
				addColor(page, e)
			elseif k == "key" then
				addKey(page, e)
			elseif k == "text" then
				addTextInput(page, e)
			end
		end
	end
end

local function applyPreset(name)
	local p = PRESETS[name]
	if not p then return end
	resetAimFeel() -- a preset is now a clean, fully-defined state for how it aims, not a patch on top of whatever was active before
	for k, v in pairs(p) do
		local e = S[k]
		if e then cfg[k] = sanitize(e, v) end
	end
	Engine.resetAimState()
	Engine.drop()
	refreshControls()
	applyAll()
	Notify(string.upper(name) .. " PRESET APPLIED", "ok")
end

-- page builders (each runs once, the first time its tab is opened) --
local BUILDERS = {}
BUILDERS.OVERVIEW = function(page)
	local dash = Row(page, 120)
	App.dashState = Label(dash, "OFF", 26, T.dim, { Font = Enum.Font.GothamBlack, Position = UDim2.new(0, 16, 0, 8), Size = UDim2.new(1, -32, 0, 34) })
	App.dashTarget = Label(dash, "No target", 14, T.text, { Font = Enum.Font.GothamBold, Position = UDim2.new(0, 16, 0, 46), Size = UDim2.new(1, -32, 0, 20) })
	App.dashCam = Label(dash, "CAMERA: OK", 11, T.dim, { Font = Enum.Font.RobotoMono, Position = UDim2.new(0, 16, 0, 70), Size = UDim2.new(1, -32, 0, 16) })
	App.dashStats = Label(dash, "", 11, T.dim, { Font = Enum.Font.RobotoMono, Position = UDim2.new(0, 16, 0, 92), Size = UDim2.new(1, -32, 0, 18) })
	buildSchema(page, "OVERVIEW")
	addHeader(page, "Quick setups")
	addButton(page, "Auto setup for this device", "primary", function()
		applyPreset(UserInputService.TouchEnabled and "Mobile" or "Universal")
		if not cfg.enabled then setCfg("enabled", true) end
	end)
	addChoice(page, "Presets", PRESET_NAMES, function() return "" end, applyPreset, 3)
	addNote(page, "Quick start: tap Auto setup, then on a phone tap AIM (or hold your aim key on PC). Use the other tabs only to fine-tune.")
end

for _, t in ipairs({ "AIM", "ACCURACY", "TARGET", "HUMAN", "ADVANCED", "PRO", "VISUAL" }) do
	BUILDERS[t] = function(page) buildSchema(page, t) end
end
BUILDERS.ELITE = function(page)
	buildSchema(page, "ELITE")
	addHeader(page, "Manual game profile")
	addChoice(page, "Apply Profile", GAME_PROFILE_NAMES, function() return App_detectedGame or "" end, function(name)
		if applyGameProfileByName(name) then
			refreshControls()
			applyAll()
			Notify(name .. " PROFILE APPLIED", "ok")
		end
	end, 2)
	addNote(page, "Known games: Rivals, Arsenal, Phantom Forces, Prison Life, Jailbreak. These are community-sourced and can go stale if a game moves to a new place -- pick one manually here if auto-detect misses.")
	addHeader(page, "Session stats")
	local statsRow = Row(page, 56)
	App.sessionLabel = Label(statsRow, "", 12, T.dim, {
		Font = Enum.Font.RobotoMono, Position = UDim2.new(0, 14, 0, 0), Size = UDim2.new(1, -28, 1, 0), TextWrapped = true,
	})
	addButton(page, "Reset Session Stats", "ghost", function()
		Engine.locks, Engine.shotsFired, Engine.sessionStart = 0, 0, os.clock()
		Notify("SESSION STATS RESET", "info")
	end)
	addHeader(page, "Config share code")
	addButton(page, "Copy Config Code", "ghost", function()
		local ok, json = pcall(function() return HttpService:JSONEncode(snapshot()) end)
		if ok and typeof(setclipboard) == "function" then
			setclipboard(json)
			Notify("CONFIG CODE COPIED", "ok")
		else
			Notify("CLIPBOARD NOT AVAILABLE ON THIS EXECUTOR", "warn")
		end
	end)
	local importRow = Row(page, 56)
	Label(importRow, "Import Config Code", 14, T.text, { Position = UDim2.new(0, 14, 0, 9), Size = UDim2.new(1, -28, 0, 20), Font = Enum.Font.GothamBold })
	local importBox = New("TextBox", {
		Font = Enum.Font.RobotoMono, TextSize = 11, BorderSizePixel = 0, Text = "", PlaceholderText = "paste code, then press enter",
		PlaceholderColor3 = T.dim, BackgroundColor3 = T.cardHi, TextColor3 = T.text, ClearTextOnFocus = false,
		Position = UDim2.new(0, 14, 0, 30), Size = UDim2.new(1, -28, 0, 20),
	}, importRow)
	Corner(importBox, 6)
	importBox.FocusLost:Connect(function(enterPressed)
		if not enterPressed or importBox.Text == "" then return end
		local ok, data = pcall(function() return HttpService:JSONDecode(importBox.Text) end)
		importBox.Text = ""
		if ok and type(data) == "table" then
			loadInto(cfg, data)
			cfg.editLayout = false
			Engine.resetAimState()
			refreshControls()
			applyAll()
			Notify("CONFIG CODE IMPORTED", "ok")
		else
			Notify("THAT DOESN'T LOOK LIKE A VALID CONFIG CODE", "err")
		end
	end)
end
BUILDERS.CONTROLS = function(page)
	buildSchema(page, "CONTROLS")
	addNote(page, "Toggle: tap AIM to latch aiming on or off. Swiping across the button never switches it. Hold: aims only while pressed.")
end

local function doSwap()
	if App.panic or not cfg.enabled then return end
	local pick = Engine.swap()
	Notify(pick and ("SWAPPED: " .. (pick.player and pick.player.DisplayName or pick.model.Name)) or "NO OTHER TARGET", pick and "ok" or "warn")
end

BUILDERS.SYSTEM = function(page)
	buildSchema(page, "SYSTEM")
	addHeader(page, "Profiles")
	addChoice(page, "Profile Slot", { "1", "2", "3" }, function() return tostring(slot) end, function(v) slot = tonumber(v) end, 3)
	addButton(page, "Save to slot", "primary", function()
		profiles[slot] = snapshot()
		Notify("PROFILE " .. slot .. " SAVED", "ok")
	end)
	addButton(page, "Load from slot", "ghost", function()
		local p = profiles[slot]
		if not p then
			Notify("PROFILE " .. slot .. " IS EMPTY", "warn")
			return
		end
		loadInto(cfg, p)
		cfg.editLayout = false
		Engine.resetAimState()
		refreshControls()
		applyAll()
		Notify("PROFILE " .. slot .. " LOADED", "ok")
	end)
	addHeader(page, "Storage")
	addButton(page, "Save settings to disk", "primary", function()
		local ok, err = Persist.save()
		if ok then
			Notify("SETTINGS SAVED", "ok")
		else
			Notify("NOT SAVED: " .. tostring(err), "err")
		end
	end)
	addButton(page, "Reset all settings", "ghost", function()
		resetCfg()
		for k, v in pairs(layoutDefaults) do layout[k] = v end
		Engine.resetAimState()
		applyAll()
		refreshControls()
		Notify("DEFAULTS RESTORED", "warn")
	end)
	addHeader(page, "Safety")
	App.panicBtn = addButton(page, "Panic: disable everything", "danger", function() setPanic(not App.panic) end)
	addButton(page, "Unload and clean up", "ghost", function() Unload() end)
	addHeader(page, "Crash recorder")
	local trRow = Row(page, 128)
	Label(trRow, Trace.summary(), 10, T.dim, {
		Font = Enum.Font.RobotoMono, Position = UDim2.new(0, 12, 0, 8), Size = UDim2.new(1, -24, 1, -16),
		TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top,
	})
	addNote(page, "Recent actions are saved to a file. After a kick or crash, reopen aimbell and read this card to see what happened last.")
	addHeader(page, "Diagnostics")
	local logRow = Row(page, 100)
	App.logLabel = Label(logRow, #App.log > 0 and table.concat(App.log, "\n", math.max(1, #App.log - 5), #App.log) or "No errors", 10, T.dim, {
		Font = Enum.Font.RobotoMono, Position = UDim2.new(0, 12, 0, 8), Size = UDim2.new(1, -24, 1, -16), TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
	})
	addButton(page, "Copy error log", "ghost", function()
		local joined = table.concat(App.log, "\n")
		if typeof(setclipboard) == "function" and joined ~= "" then
			setclipboard(joined)
			Notify("LOG COPIED", "ok")
		else
			Notify(joined == "" and "LOG IS EMPTY" or "CLIPBOARD NOT AVAILABLE", "warn")
		end
	end)
	addNote(page, fsOk and "File API available: settings persist between sessions." or "No file API here: settings last for this session only.")
	addNote(page, "A kick is the game's own anti-cheat decision. This build avoids huge instant camera snaps, stacks errors into Panic instead of crashing, and falls back to Mouse aim in games that fight back on the camera -- but no client script can guarantee a specific game won't kick you.", T.dim)
end

local function selectTab(name)
	if name == currentTab then return end
	currentTab = name
	if not built[name] then
		built[name] = true
	local function newPage(name)
		local page = New("ScrollingFrame", {
			Name = name, BackgroundTransparency = 1, BorderSizePixel = 0, Visible = false, Size = UDim2.fromScale(1, 1),
			ScrollBarThickness = 3, ScrollBarImageColor3 = T.off, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
		}, body)
		New("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, page)
		New("UIPadding", { PaddingRight = UDim.new(0, 8), PaddingBottom = UDim.new(0, 10), PaddingTop = UDim.new(0, 2) }, page)
		pages[name] = page
		return page
	end

		local page = newPage(name)
		BUILDERS[name](page)
	end
	for tabName, page in pairs(pages) do page.Visible = tabName == name end
	local idx = table.find(TABS, name)
	Tw(selector, { Position = UDim2.new(0, 6, 0, 6 + (idx - 1) * TAB_STEP) }, 0.22)
	for tabName, b in pairs(tabButtons) do
		Tw(b, { TextColor3 = tabName == name and T.text or T.dim }, 0.15)
	end
	local page = pages[name]
	page.Position = UDim2.fromOffset(14, 0)
	Tw(page, { Position = UDim2.new() }, 0.2)
end
for i, name in ipairs(TABS) do
	local b = New("TextButton", {
		Text = name, Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = T.dim, BackgroundTransparency = 1, AutoButtonColor = false,
		Position = UDim2.new(0, 6, 0, 6 + (i - 1) * TAB_STEP), Size = UDim2.new(1, -12, 0, TAB_H), ZIndex = 2,
	}, tabScroll)
	b.Activated:Connect(function() selectTab(name) end)
	tabButtons[name] = b
end

-- floating, aim and swap buttons ------------------------------------
local function mkRoundBtn(name, text, px)
	local b = New("TextButton", {
		Name = name, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(px, px), BackgroundColor3 = T.bg, Text = text,
		Font = Enum.Font.GothamBlack, TextSize = 14, TextColor3 = Accent.color, AutoButtonColor = false, Visible = false, BorderSizePixel = 0,
	}, hudLayer)
	Round(b)
	return b, Stroke(b, Accent.color, 2, 0.1)
end
local aimBtn, aimBtnStroke = mkRoundBtn("AimButton", "AIM", 76)
local swBtn, swBtnStroke = mkRoundBtn("SwapButton", "SWAP", 54)
local floatBtn, floatStroke = mkRoundBtn("FloatingButton", "", 46)
floatBtn.Visible = true
floatBtn.BackgroundTransparency = 0.05
local floatMark, fmStroke, fmHalo, fmDot = eyeGlyph(floatBtn, 24, UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5))
local function floatColor()
	local c = App.panic and T.bad or Accent.color
	floatStroke.Color, fmStroke.Color, fmHalo.BackgroundColor3, fmDot.BackgroundColor3 = c, c, c, c
end

local function setAimVisual(on)
	if on == App.aimOn then return end
	App.aimOn = on
	aimBtn.BackgroundColor3 = on and Accent.color or T.bg
	aimBtn.TextColor3 = on and T.bg or Accent.color
end

local function applyLayout()
	win.Position = UDim2.fromScale(layout.menuCX, layout.menuCY)
	floatBtn.Position = UDim2.fromScale(layout.floatX, layout.floatY)
	aimBtn.Position = UDim2.fromScale(layout.aimX, layout.aimY)
	swBtn.Position = UDim2.fromScale(layout.swX, layout.swY)
end

local menuOpen = true
local function setMenu(open)
	if open == menuOpen then return end
	menuOpen = open
	if open then
		win.Visible = true
		winScale.Scale = 0.94
		Tw(winScale, { Scale = 1 }, 0.16)
	else
		Tw(winScale, { Scale = 0.94 }, 0.12)
		task.delay(0.12, function()
			if App.alive and not menuOpen then win.Visible = false end
		end)
	end
end

makeMovable(titleBar, win, nil, nil, function()
	local vp, sz = gui.AbsoluteSize, win.AbsoluteSize
	local c = win.AbsolutePosition + sz * 0.5
	layout.menuCX = math.clamp(c.X / math.max(vp.X, 1), 0.1, 0.9)
	layout.menuCY = math.clamp(c.Y / math.max(vp.Y, 1), 0.1, 0.9)
	win.Position = UDim2.fromScale(layout.menuCX, layout.menuCY)
end)
makeMovable(floatBtn, floatBtn, nil, function() setMenu(not menuOpen) end, function() commitPos(floatBtn, "floatX", "floatY") end)
makeMovable(aimBtn, aimBtn, function() return cfg.editLayout end, nil, function() commitPos(aimBtn, "aimX", "aimY") end)
makeMovable(swBtn, swBtn, function() return cfg.editLayout end, nil, function() commitPos(swBtn, "swX", "swY") end)

-- The AIM button reacts to a clean tap or a hold only. A swipe that starts on it, or
-- crosses it, can never switch aiming off by accident.
aimBtn.InputBegan:Connect(function(input)
	if cfg.editLayout or App.panic or not isPointer(input) or App.btnInput then return end
	App.btnInput, App.btnStart, App.btnTime, App.btnMoved = input, input.Position, os.clock(), false
	if cfg.buttonMode == "Hold" then
		if not cfg.enabled then setCfg("enabled", true) end
		Engine.buttonHeld = true
		Engine.needsRepress, Engine.nextScan = false, 0
	end
end)
swBtn.Activated:Connect(function()
	if not cfg.editLayout then doSwap() end
end)

-- drag the FOV circle's handle to resize the aim FOV directly on screen
O.fovHandle.InputBegan:Connect(function(input)
	if not isPointer(input) then return end
	local scale = Engine.fovCurrent / math.max(cfg.fov, 1)
	Drag.start(input, function(p)
		local r = math.abs(p.X - gui.AbsoluteSize.X * 0.5)
		local v = math.clamp(math.floor(r / scale / 5 + 0.5) * 5, S.fov.min, S.fov.max)
		if v ~= cfg.fov then
			cfg.fov = v
			Engine.fovCurrent = v * scale
			if Refresh.fov then Refresh.fov() end
			applyAll()
		end
	end)
end)

-- apply layer ------------------------------------------------------
applyAll = function()
	local function applyCrosshair()
		local style, size, th = cfg.crossStyle, cfg.crossSize, cfg.crossThickness
		local col = ACCENTS[cfg.crossColor]
		O.xhRoot.Visible = cfg.crosshair and not App.panic
		local gap = 3
		local barOn = style == "Plus" or style == "X"
		for i = 1, 4 do
			local b = O.xhBars[i]
			b.Visible = barOn
			b.BackgroundColor3 = col
			if barOn then
				local ang = math.rad((i - 1) * 90 + (style == "X" and 45 or 0))
				local d = gap + size * 0.5
				b.Size = UDim2.fromOffset(size, th)
				b.Position = UDim2.fromOffset(math.cos(ang) * d, math.sin(ang) * d)
				b.Rotation = math.deg(ang)
			end
		end
		O.xhDot.Visible = style == "Dot" or style == "Plus"
		O.xhDot.BackgroundColor3 = col
		local dot = style == "Dot" and th * 2 + 2 or th
		O.xhDot.Size = UDim2.fromOffset(dot, dot)
		O.xhRing.Visible = style == "Ring"
		O.xhRing.Size = UDim2.fromOffset(size * 1.6, size * 1.6)
		O.xhRingStroke.Color, O.xhRingStroke.Thickness = col, th
	end

	local function applyInfoLayout()
		local hp, dist = cfg.showHealth, cfg.showDistance
		O.infoBar.Visible, O.infoFill.Visible = hp, hp
		O.info.Size = UDim2.fromOffset(230, hp and 56 or 46)
		O.infoMeta.Visible = hp or dist or cfg.showMeter
	end

	local function refreshLoop()
		local need = (not App.panic) and (cfg.enabled or cfg.showFps or cfg.showPerf or cfg.showCount)
		if need and not App.loopBound then
			refreshRoster()
			RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Last.Value, guardedStep)
			App.loopBound = true
		elseif not need and App.loopBound then
			RunService:UnbindFromRenderStep(BIND_NAME)
			App.loopBound = false
			Engine.drop()
			Engine.out.c = nil
			Engine.ghost = nil
			O.ghost.Visible = false
			Overlay.hideTarget()
			setAimVisual(false)
		end
		if not App.loopBound then Engine.fovCurrent = cfg.fov end
	end

	local function applyVisuals()
		local show = not App.panic
		local col = ACCENTS[cfg.fovColor]
		O.fov.Visible = show and cfg.showFov
		O.fovStroke.Color, O.fovStroke.Thickness, O.fovStroke.Transparency = col, cfg.fovThickness, cfg.fovTransparency
		O.fov.BackgroundColor3 = col
		O.fov.BackgroundTransparency = cfg.fovFilled and math.clamp(0.82 + cfg.fovTransparency * 0.18, 0, 1) or 1
		lastR = -1
		setFovSize(Engine.fovCurrent)
		O.fovHandle.Visible = O.fov.Visible and cfg.fovHandle
		O.fovHandleStroke.Color = col
		O.hud.Visible = show and App.loopBound and (cfg.showFps or cfg.showPerf or cfg.showCount)
	end

	local function applyButtons()
		local show = not App.panic
		local edit = cfg.editLayout
		local s, tr = cfg.btnScale, 1 - cfg.btnOpacity
		aimBtn.Visible = show and (cfg.showAimButton or edit)
		swBtn.Visible = show and (cfg.showSwitchButton or edit)
		aimBtn.Size = UDim2.fromOffset(76 * s, 76 * s)
		swBtn.Size = UDim2.fromOffset(54 * s, 54 * s)
		aimBtn.BackgroundTransparency, swBtn.BackgroundTransparency = tr, tr
		aimBtn.Text, swBtn.Text = edit and "MOVE" or "AIM", edit and "MOVE" or "SWAP"
		local ec = edit and T.warn or (cfg.enabled and Accent.color or T.dim)
		aimBtnStroke.Color, swBtnStroke.Color = ec, ec
		swBtn.TextColor3 = ec
		aimBtn.TextColor3 = edit and T.warn or (App.aimOn and T.bg or ec)
		floatColor()
	end

	if not App.alive then return end
	refreshLoop()
	applyVisuals()
	applyCrosshair()
	applyInfoLayout()
	applyButtons()
	if not cfg.enabled then Engine.resetAimState() end
	if not App.loopBound then
		setStatus(App.panic and "PANIC" or "OFF", App.panic and T.bad or T.dim)
		if App.dashState then
			App.dashState.Text, App.dashState.TextColor3 = App.panic and "PANIC" or "OFF", App.panic and T.bad or T.dim
		end
	end
end

setCfg = function(key, value)
	local e = S[key]
	if not e then return end
	cfg[key] = sanitize(e, value)
	if e.kind ~= "num" then Trace.add("SET " .. key .. "=" .. tostring(cfg[key])) end
	if Refresh[key] then Refresh[key]() end
	onChanged(key)
end

onChanged = function(key)
	if key == "enabled" or key == "aimMode" then
		Engine.resetAimState()
		setAimVisual(false)
		Notify(key == "enabled" and (cfg.enabled and "THE EYE IS OPEN" or "THE EYE IS CLOSED") or ("MODE: " .. string.upper(cfg.aimMode)), cfg.enabled and "ok" or "warn")
	elseif key == "editLayout" then
		Notify(cfg.editLayout and "DRAG THE BUTTONS TO MOVE THEM" or "LAYOUT LOCKED", "info")
	elseif key == "accent" then
		Accent.set(cfg.accent)
		floatColor()
	elseif key == "npcs" then
		trackNpcs(cfg.npcs)
		if App.loopBound then refreshRoster() end
	elseif key == "method" or key == "autoFallback" then
		Engine.fight, Engine.camBlocked, Engine.autoMouse = 0, false, false
	elseif key == "targetPart" or key == "priority" then
		Engine.aimPoint = nil
	end
	applyAll()
end

refreshControls = function()
	for _, fn in pairs(Refresh) do fn() end
	Accent.set(cfg.accent)
end

-- main per-frame step (bound only while needed) --------------------
guardedStep = function(dt)
	local traceHandler = function(e) return tostring(e) end
	local function logError(tag, err)
		App.log[#App.log + 1] = ("[%s] %s: %s"):format(os.date("%H:%M:%S"), tag, tostring(err))
		if #App.log > 40 then table.remove(App.log, 1) end
		if App.logLabel then
			App.logLabel.Text = table.concat(App.log, "\n", math.max(1, #App.log - 5), #App.log)
		end
	end

	local ok, err = xpcall(step, traceHandler, dt)
	if ok then return end
	logError("step", err)
	Trace.add("ERROR " .. tostring(err))
	local now = os.clock()
	local list = App.errors
	list[#list + 1] = now
	while list[1] and now - list[1] > 3 do table.remove(list, 1) end
	if #list >= 5 then
		App.errors = {}
		setCfg("enabled", false)
		Notify("STOPPED AFTER REPEATED ERRORS - SEE SYSTEM > DIAGNOSTICS", "err", true)
		if cfg.smartRecovery then
			task.delay(5, function()
				if App.alive and not cfg.enabled and not App.panic then
					setCfg("enabled", true)
					Notify("SMART RECOVERY: RESUMED - WATCHING FOR MORE ERRORS", "info", true)
				end
			end)
		end
	end
end

local statusAimOn
step = function(dt)
	if not App.alive then return end
	local t0 = os.clock()
	local cdt = math.min(dt, 0.1)
	Engine.out.c = nil
	local aiming = false
	if cfg.enabled and not App.panic then aiming = Engine.step(cdt, t0) end
	if Engine.fovUiDirty then
		Engine.fovUiDirty = false
		if Refresh.fov then Refresh.fov(cfg.fov) end
	end
	Overlay.render(cdt)

	if not cfg.enabled then
		setStatus("OFF", T.dim)
	elseif aiming then
		if Engine.locked then setStatus("LOCK", Accent.color) else setStatus("SEEK", T.warn) end
	else
		setStatus("ARMED", Accent.color)
	end
	if aiming ~= statusAimOn then
		statusAimOn = aiming
		if not cfg.editLayout then setAimVisual(aiming) end
	end

	-- dashboard (a few times per second, only if that page exists)
	App.fpsAcc += dt
	App.fpsFrames += 1
	App.costAcc += os.clock() - t0
	App.pingAcc += dt
	if App.pingAcc >= 1 then
		App.pingAcc = 0
		pcall(function() Engine.ping = StatsService.Network.ServerStatsItem["Data Ping"]:GetValue() end)
	end
	if cfg.adaptivePerf and App.fpsFrames > 0 then
		local liveFps = App.fpsFrames / math.max(App.fpsAcc, 0.001)
		if liveFps < 20 and not cfg.liteUI and not App.autoLiteApplied then
			App.autoLiteApplied = true
			setCfg("liteUI", true)
			Notify("LOW FPS - LITE UI ENABLED", "warn")
		elseif liveFps > 35 then
			App.autoLiteApplied = false -- allows Adaptive Performance to react again if FPS drops again later
		end
	end
	if App.fpsAcc >= 0.5 then
		local fps = math.floor(App.fpsFrames / App.fpsAcc + 0.5)
		local count = cfg.showCount and ("TARGETS IN VIEW: " .. cand.n) or nil
		if O.hud.Visible then
			local ms = App.fpsAcc / App.fpsFrames * 1000
			local cost = App.costAcc / App.fpsFrames * 1000
			local mb = collectgarbage("count") / 1024
			local base
			if cfg.showFps and cfg.showPerf then
				base = string.format("FPS %d  FT %.1fms\nAIM %.2fms  ROSTER %d\nLUA %.1fMB", fps, ms, cost, rosterN, mb)
			elseif cfg.showFps then
				base = string.format("FPS %d", fps)
			elseif cfg.showPerf then
				base = string.format("FT %.1fms  AIM %.2fms\nROSTER %d  LUA %.1fMB", ms, cost, rosterN, mb)
			end
			O.hud.Text = (base and count) and (base .. "\n" .. count) or (base or count or "")
		end
		if App.dashState and App.dashState.Parent and pages.OVERVIEW and pages.OVERVIEW.Visible then
			local c = Engine.out.c
			local label, tone
			if not cfg.enabled then label, tone = "OFF", T.dim
			elseif aiming and Engine.locked then label, tone = "LOCKED", T.good
			elseif aiming then label, tone = "SEEKING", T.warn
			else label, tone = "ARMED", Accent.color end
			App.dashState.Text, App.dashState.TextColor3 = label, tone
			local dashDist = c and (cfg.distanceUnit == "Meters" and ("%dm"):format(math.floor(c.wd * 0.28 + 0.5)) or ("%d st"):format(math.floor(c.wd + 0.5))) or ""
			App.dashTarget.Text = c and ((c.e.player and c.e.player.DisplayName or c.e.model.Name) .. "   " .. dashDist) or "No target"
			App.dashStats.Text = ("%d FPS   %d ms   %d locks   ON %d%%"):format(fps, math.floor(Engine.ping), Engine.locks, math.floor(Engine.meter * 100 + 0.5))
			if App.sessionLabel then
				local mins = (os.clock() - Engine.sessionStart) / 60
				local rate = Engine.shotsFired > 0 and math.floor(Engine.locks / Engine.shotsFired * 100 + 0.5) or 0
				App.sessionLabel.Text = ("%d locks   %d shots   ~%d%% on-target   %.1f min session"):format(Engine.locks, Engine.shotsFired, rate, mins)
			end
			if App.dashCam then
				App.dashCam.Text = Engine.camBlocked and (Engine.autoMouse and "CAMERA: GAME FIGHTS IT - USING MOUSE AIM" or "CAMERA: GAME CONTROLS IT - CAN'T STEER") or "CAMERA: OK"
				App.dashCam.TextColor3 = Engine.camBlocked and T.warn or T.dim
			end
		end
		App.fpsAcc, App.fpsFrames, App.costAcc = 0, 0, 0
	end
end

-- panic / close ------------------------------------------------------
setPanic = function(on)
	App.panic = on
	if on then
		Engine.resetAimState()
		Engine.drop()
		setAimVisual(false)
	end
	if App.panicBtn then App.panicBtn.Text = on and "Restore all modules" or "Panic: disable everything" end
	floatColor()
	applyAll()
	Notify(on and "PANIC: ALL MODULES DISABLED" or "MODULES RESTORED", on and "err" or "ok", true)
end
panicTitleBtn.Activated:Connect(function() setPanic(not App.panic) end)
minBtn.Activated:Connect(function() setMenu(false) end)

local closeArmed = false
closeBtn.Activated:Connect(function()
	if not closeArmed then
		closeArmed = true
		closeBtn.Text, closeBtn.TextColor3, closeStroke.Color = "?", T.bad, T.bad
		task.delay(2, function()
			if App.alive and closeArmed then
				closeArmed = false
				closeBtn.Text, closeBtn.TextColor3, closeStroke.Color = "X", T.dim, T.line
			end
		end)
	else
		Unload()
	end
end)

-- 9 ===================== INPUT + BOOT =============================
local function keyMatches(input)
	local k = cfg.aimKey
	return input.KeyCode.Name == k or input.UserInputType.Name == k
end

Janitor.connect(UserInputService.InputBegan, function(input, processed)
	local L = App.listening
	if L then -- rebinding the aim key
		local name
		if input.KeyCode == Enum.KeyCode.Escape then
			L.cancel()
			return
		elseif input.KeyCode ~= Enum.KeyCode.Unknown then
			name = input.KeyCode.Name
		elseif input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.MouseButton2 or input.UserInputType == Enum.UserInputType.MouseButton3 then
			name = input.UserInputType.Name
		end
		if name then
			App.listening = nil
			L.cb(name)
		end
		return
	end
	if processed then return end
	if input.KeyCode.Name == cfg.panicKey then
		setPanic(not App.panic)
		return
	end
	if input.KeyCode.Name == cfg.menuKey then
		setMenu(not menuOpen)
		return
	end
	if input.KeyCode.Name == cfg.swapKey then
		doSwap()
		return
	end
	if input.KeyCode.Name == cfg.partCycleKey then
		local order = { "Head", "Torso", "Root", "Closest" }
		local nextPart = order[(table.find(order, cfg.targetPart) or 0) % #order + 1]
		setCfg("targetPart", nextPart)
		Notify("AIM PART: " .. string.upper(nextPart), "info")
		return
	end
	if input.KeyCode.Name == cfg.priorityKey then
		App.priorityHeld = true
	end
	if not App.panic and keyMatches(input) then Engine.aimInput(true) end
end)

Janitor.connect(UserInputService.InputEnded, function(input)
	if input.KeyCode.Name == cfg.priorityKey then App.priorityHeld = false end
	local di = Drag.input
	if di and (input == di or (input.UserInputType == Enum.UserInputType.MouseButton1 and di.UserInputType == Enum.UserInputType.MouseButton1)) then
		Drag.stop()
	end
	local b = App.btnInput
	if b and (input == b or (input.UserInputType == Enum.UserInputType.MouseButton1 and b.UserInputType == Enum.UserInputType.MouseButton1)) then
		local tap = not App.btnMoved and os.clock() - App.btnTime < 0.6
		App.btnInput = nil
		if cfg.buttonMode == "Hold" then
			Engine.buttonHeld = false
			if not Engine.isAiming() then Engine.locked = false end
		elseif tap and not cfg.editLayout then
			if not cfg.enabled then
				setCfg("enabled", true)
				Engine.buttonLatched = true
			else
				Engine.buttonLatched = not Engine.buttonLatched
			end
			Engine.needsRepress, Engine.nextScan = false, 0
			if not Engine.buttonLatched and not Engine.isAiming() then Engine.locked = false end
		end
	elseif cfg.aimMode == "Hold" and not b and keyMatches(input) then
		Engine.aimInput(false)
	elseif cfg.aimMode == "Hold" and keyMatches(input) then
		Engine.aimInput(false)
	end
end)

Janitor.connect(UserInputService.InputChanged, function(input)
	local di = Drag.input
	if di and (input == di or (di.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseMovement)) then
		Drag.fn(input.Position)
	end
	local b = App.btnInput
	if b and (input == b or (b.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseMovement)) then
		if (input.Position - App.btnStart).Magnitude > 12 then App.btnMoved = true end
	end
end)

-- Swipe To Switch: a two-finger swipe cycles the target. Two fingers are distinct from the
-- single-finger drag Roblox uses to look around, so the camera is never fought for control.
local swipeTouches, swipeBaseX, swipeLastTrigger = {}, nil, 0
local function swipeAvgX()
	local sum, n = 0, 0
	for _, pos in pairs(swipeTouches) do
		sum += pos.X
		n += 1
	end
	return n > 0 and sum / n or nil
end
Janitor.connect(UserInputService.TouchStarted, function(touch, processed)
	if not cfg.swipeSwitch then return end
	swipeTouches[touch] = touch.Position
	if UserInputService:GetTouches() and #UserInputService:GetTouches() == 2 then
		swipeBaseX = swipeAvgX()
	end
end)
Janitor.connect(UserInputService.TouchMoved, function(touch, processed)
	if not cfg.swipeSwitch or not swipeBaseX then return end
	swipeTouches[touch] = touch.Position
	local touches = UserInputService:GetTouches()
	if not touches or #touches ~= 2 then return end
	local avg = swipeAvgX()
	if not avg then return end
	local delta = avg - swipeBaseX
	local now = os.clock()
	if math.abs(delta) >= cfg.swipeThreshold and now - swipeLastTrigger > 0.18 then
		swipeLastTrigger = now
		swipeBaseX = avg -- re-baseline so one continuous swipe can cycle through several targets
		doSwap()
	end
end)
Janitor.connect(UserInputService.TouchEnded, function(touch, processed)
	swipeTouches[touch] = nil
	local touches = UserInputService:GetTouches()
	if not touches or #touches < 2 then swipeBaseX = nil end
end)

Janitor.connect(gui:GetPropertyChangedSignal("AbsoluteSize"), function()
	layoutWindow()
	applyAll()
end)

-- the roster only needs a slow refresh
task.spawn(function()
	while App.alive do
		if App.loopBound then refreshRoster() end
		task.wait(0.5)
	end
end)

Unload = function()
	if not App.alive then return end
	Trace.add("UNLOAD")
	Trace.flush()
	App.alive = false
	Drag.stop()
	pcall(function() RunService:UnbindFromRenderStep(BIND_NAME) end)
	App.loopBound = false
	Janitor.clean()
	if genv.__AIMBELL_UNLOAD == Unload then genv.__AIMBELL_UNLOAD = nil end
end
genv.__AIMBELL_UNLOAD = Unload

-- boot
RunService.Heartbeat:Wait()
layoutWindow()
applyLayout()
Accent.set(cfg.accent)
if cfg.npcs then trackNpcs(true) end
selectTab("OVERVIEW")
applyAll()
Trace.start()
Notify(loadedFromDisk and "AIMBELL ONLINE - SETTINGS LOADED" or "AIMBELL ONLINE", "ok")
if App_detectedGame and cfg.profileNotify and not loadedFromDisk then
	Notify("GAME DETECTED: " .. string.upper(App_detectedGame) .. " - TUNED DEFAULTS APPLIED", "info")
end
if Trace.unclean then Notify("LAST SESSION ENDED UNEXPECTEDLY - SEE SYSTEM > CRASH RECORDER", "warn") end
task.spawn(function()
	while App.alive do
		task.wait(1)
		Trace.flush()
	end
end)
if not fsOk then Notify("NO FILE API: SETTINGS ARE SESSION-ONLY", "warn") end
