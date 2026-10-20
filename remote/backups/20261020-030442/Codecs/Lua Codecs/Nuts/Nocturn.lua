--[[
	Novation Nocturn — Reason Remote codec
	======================================

	Author:   Kester
	Project:  nuts (Novation Nocturn driver -> Reason Remote)
	Reason:   Reason 10+ running the Lua Remote SDK (Lua 5.1 sandbox).
	Device:   Novation Nocturn (hardware). The surface is registered in Reason
	          under the manufacturer "Nuts" - not "Novation" - so it is
	          unmistakable in the device list and cannot be confused with the
	          factory Novation surfaces. The nuts driver owns the USB device
	          and exposes it to the DAW as a MIDI loopback endpoint named
	          "Nocturn"; Reason therefore sees a plain MIDI port called
	          Nocturn.

	Description
	-----------
	Two-way Remote codec for the Novation Nocturn. It provides the control
	surface items consumed by Maps/Nuts/Nocturn.remotemap.

	The Nocturn has NO keybed and NO pads, so there is no Keyboard item and no
	pad mapping - only the 8 dials, the 8 page-row buttons, the 8 PermaBar
	buttons, the Speed Dial and the Crossfader.

	The surface is used as ONE mixer channel at a time ("page = channel"): the
	8 dials are the selected channel's parameters, the 8 buttons are its
	switches, and the channel itself is Reason's "Remote Base Channel". The
	.remotemap targets "Channel 1 <param>", and Reason re-bases every such line
	onto the selected channel, so the whole channel-strip layout lives in the
	.remotemap and nothing here needs to change if the layout changes.

	MIDI assignment table (driver-side defaults, verified by live capture):

		Control                      MIDI (channel 1)       Item
		-------------------------    -------------------    ------------------
		Dial 1..8                    CC16-23, relative      Knob 1..8
		Dial 1..8 touch              CC80-87                (reserved)
		Button 1..8 (green LEDs)     CC102-109, state       Button 1..8
		PermaBar Page -/+            CC112/113              Page Left/Right
		Speed Dial                   CC24, relative         Speed Dial
		Speed Dial click             CC118                  Speed Dial Button
		Crossfader                   CC8 (MSB), CC9 (LSB)   Crossfader
		Crossfader touch             CC89                   (reserved)

		Codec -> device (feedback):  CC32-39 knob ring values 0-11,
		                             CC40 speed dial ring value 0-11,
		                             CC48-55 knob ring modes 0-5,
		                             CC102-109 button LEDs (0/127).

	Notes
	-----
	- These numbers are a three-way contract: src/Nuts.Driver/appsettings.json
	  (Midi:Mapping), remote/mapping/nocturn-controls.json and the lookup tables
	  below. Change all three together.
	- The dials and the Speed Dial are endless encoders: every detent sends a
	  two's complement delta (1..63 = clockwise, 65..127 = counter-clockwise).
	  They are declared as input="delta" items, so Reason accumulates the delta
	  itself and the ring always shows the parameter's true value (no soft
	  takeover / pickup sweep is needed).
	- The page-row buttons are input="value" items (min 0, max 127) and the
	  driver's button kind for that row is "toggle"
	  (src/Nuts.Driver/appsettings.json -> Midi:Mapping:ButtonKinds): the driver
	  owns the latch and sends the switch's STATE (127 = on, 0 = off), which
	  Reason applies to the Toggle remotables (Mute, Solo, EQ On, ...). A
	  "button" item only says press/release and Reason ignores the release, so
	  edges would switch a toggle only once per two presses - measured, and
	  written up in docs/midi-mapping.md. The two settings are coupled; change
	  them together. Page -/+ stay button items: a trigger wants a press.
	- The switches are on CCs, not notes, and that is deliberate: a CC carries
	  an absolute value (which is what a switch state is) and it keeps the
	  whole note range on the loopback free for a keyboard. The Nocturn's own
	  buttons are notes on its USB wire; the driver re-publishes them as these
	  CCs, and it maps the LED CCs back to the hardware's note LED addresses.
	  If the surface ever gains a keyboard item, nothing collides.
	- The LEDs are on/off only and each ring LED has a fixed colour per
	  position. Rings are driven from Reason's item feedback by the
	  auto-outputs below (item value 0-127 -> 0-11 segments); the ring *modes*
	  are set once in remote_prepare_for_use(). Ring scaling and the mode
	  choices are still being tuned.
	- The ring modes match the .remotemap layout (dial 2 = Pan, dials 3-6 =
	  EQ gains). If you re-order the dials in the .remotemap, update
	  gRingModes here to match.
]]

--------------------------------------------------------------------------
-- Item indices (1-based, in remote.define_items() order below)
--------------------------------------------------------------------------
gScopeItemIndex       = 1   -- _Scope
gFirstKnobIndex       = 2   -- Knob 1..8          -> 2..9
gNumberOfKnobs        = 8
gFirstButtonIndex     = 10  -- Button 1..8        -> 10..17
gPageLeftIndex        = 18
gPageRightIndex       = 19
gSpeedDialIndex       = 20
gSpeedDialButtonIndex = 21
gCrossfaderIndex      = 22

--------------------------------------------------------------------------
-- MIDI <-> control lookup tables
--------------------------------------------------------------------------
-- CC -> dial number (1-8). Relative encoders, driver defaults CC16-23.
gKnobCCLookup = {
	[0x10]=1, [0x11]=2, [0x12]=3, [0x13]=4,
	[0x14]=5, [0x15]=6, [0x16]=7, [0x17]=8,
}

gSpeedDialCC       = 0x18  -- CC24, relative (same encoding as the dials)
gCrossfaderMSBCC   = 0x08  -- CC8  = crossfader MSB
gCrossfaderLSBCC   = 0x09  -- CC9  = crossfader LSB (unused)
gEncoderTouchBase  = 0x50  -- CC80-87: dial touch (127 down / 0 up), reserved
gSpeedDialTouchCC  = 0x58  -- CC88
gCrossfaderTouchCC = 0x59  -- CC89

-- CC -> item index for the switches. They are CCs and not notes: a CC carries
-- an absolute value (which is exactly what a switch state is) and it keeps the
-- whole note range on the loopback free for a keyboard. The Nocturn's own
-- buttons are notes on its USB wire; the driver re-publishes them as these
-- CCs. Surface order is page row first, then PermaBar (Learn, View, Page-,
-- Page+, User, FX, INST, MIXER). Only the page-row buttons and Page -/+ are
-- given items for now - the remaining PermaBar buttons are deliberately left
-- unmapped.
gButtonCcLookup = {
	[0x66]=10, [0x67]=11, [0x68]=12, [0x69]=13,
	[0x6a]=14, [0x6b]=15, [0x6c]=16, [0x6d]=17,
	[0x70]=18, -- CC112 Page Left  (PermaBar index 10)
	[0x71]=19, -- CC113 Page Right (PermaBar index 11)
}

gSpeedDialClickCC = 0x76  -- CC118: Speed Dial click (the only "press" on it)

-- Which switches are physically down, keyed by item index. The loopback hands
-- every client the messages written by every other client, so Reason's own
-- button-LED CCs (the same CCs as the switch states) come back in through the
-- In Port as a second press and would toggle a mapped switch twice. A real
-- button must be released before it can be pressed again, so a repeat "down"
-- while this flag is set can only be that echo.
gButtonDown = {}

-- Codec -> device LED addresses (sent to the driver over the loopback; the
-- driver turns them into the hardware's own LED commands).
gRingValueBase        = 0x20  -- CC32-39: knob ring values 0-11
gSpeedDialRingValueCC = 0x28  -- CC40:    speed dial ring value 0-11
gRingModeBase         = 0x30  -- CC48-55: knob ring modes 0-5
gButtonCcBase         = 0x66  -- CC102-109: page-row button LEDs (0/127)

-- Set to -1 if the dials feel inverted on your unit. Both the hardware and
-- the driver forward the raw two's-complement byte; this only flips the
-- interpretation, so it is a one-line fix without touching the driver.
gEncoderDirection = 1

-- Encoder ring mode per dial, matching the .remotemap channel-strip layout:
--   1 Level               -> 0  fill from minimum
--   2 Pan                 -> 3  centre, both directions
--   3..6 HF/HMF/LMF/LF Gain -> 3  centre, both directions
--   7..8 FX1/FX2 Send Level -> 0  fill from minimum
gRingModes = { 0, 3, 3, 3, 3, 3, 0, 0 }

-- The focused scope name (from "Map _Scope ..."), kept for the LED/context
-- work that comes after the channel strip is verified.
gScope = ""

--------------------------------------------------------------------------
-- remote_init
--------------------------------------------------------------------------
function remote_init(manufacturer, model)
	local items = {
		-- Scope-name display item consumed by the "Map _Scope ..." line.
		{name="_Scope", output="text"},

		-- Endless encoders: input="delta" lets Reason accumulate the
		-- two's-complement delta we hand it in remote_process_midi().
		{name="Knob 1", input="delta", output="value", min=0, max=127},
		{name="Knob 2", input="delta", output="value", min=0, max=127},
		{name="Knob 3", input="delta", output="value", min=0, max=127},
		{name="Knob 4", input="delta", output="value", min=0, max=127},
		{name="Knob 5", input="delta", output="value", min=0, max=127},
		{name="Knob 6", input="delta", output="value", min=0, max=127},
		{name="Knob 7", input="delta", output="value", min=0, max=127},
		{name="Knob 8", input="delta", output="value", min=0, max=127},

		-- Page-row buttons, above the dials (green LEDs). These are the
		-- channel's switches (Mute, Solo, EQ On, ...), and the driver sends
		-- their STATE: 127 = on, 0 = off (kind "toggle", see ButtonLogic).
		--
		-- That is why they are "value" items and not "button" items. The
		-- item type decides what Reason does with the number (Remote SDK
		-- 5.1.2 / 6.4.15): a "button" item only says "pressed" and
		-- "released", and Reason's Toggle remotables act on the press edge
		-- alone - a 0 is just the release and switches nothing. Measured on
		-- this codec with button items: press 1 lit the LED and switched
		-- Mute on, press 2 darkened the LED and left Mute on. A "value"
		-- item "sends the absolute value of the control surface", so 0 and
		-- 127 are both real values and Reason sets the toggle from them -
		-- which is how the factory maps drive toggles from faders and knobs
		-- (e.g. Axiom Pro maps Knob 4 onto "LF On").
		--
		-- COUPLING: these items assume Midi:Mapping:ButtonKinds:PageRow =
		-- "toggle" in the driver. With "momentary" the release would arrive
		-- here as an absolute 0 and switch the target off while held.
		{name="Button 1", input="value", output="value", min=0, max=127},
		{name="Button 2", input="value", output="value", min=0, max=127},
		{name="Button 3", input="value", output="value", min=0, max=127},
		{name="Button 4", input="value", output="value", min=0, max=127},
		{name="Button 5", input="value", output="value", min=0, max=127},
		{name="Button 6", input="value", output="value", min=0, max=127},
		{name="Button 7", input="value", output="value", min=0, max=127},
		{name="Button 8", input="value", output="value", min=0, max=127},

		-- PermaBar: only the channel-window navigation for now.
		{name="Page Left", input="button"},
		{name="Page Right", input="button"},

		{name="Speed Dial", input="delta", output="value", min=0, max=127},
		{name="Speed Dial Button", input="button"},

		{name="Crossfader", input="value", output="value", min=0, max=127},
	}
	remote.define_items(items)

	-- LED feedback. Item value 0-127 -> 0-11 ring segments (the driver clamps
	-- to 11) or 0/127 for the button LEDs.
	local outputs = {}

	for i = 1, gNumberOfKnobs do
		outputs[#outputs + 1] = {
			name = "Knob " .. i,
			pattern = string.format("b0 %02x 0<00xx>", gRingValueBase + i - 1),
			x = "value*11/127",
		}
	end

	outputs[#outputs + 1] = {
		name = "Speed Dial",
		pattern = string.format("b0 %02x 0<00xx>", gSpeedDialRingValueCC),
		x = "value*11/127",
	}

	-- The button LEDs are value items with min 0 max 127, so Reason's
	-- feedback arrives as 0 or 127 and the CC value is that value directly.
	for i = 1, 8 do
		outputs[#outputs + 1] = {
			name = "Button " .. i,
			pattern = string.format("b0 %02x xx", gButtonCcBase + i - 1),
			x = "value",
		}
	end

	remote.define_auto_outputs(outputs)
end

--------------------------------------------------------------------------
-- remote_prepare_for_use  (clear the surface, install the ring modes)
--------------------------------------------------------------------------
function remote_prepare_for_use()
	local events = {}

	-- Forget any button that was down when the surface was last released, so
	-- a lost release cannot leave a button deaf.
	gButtonDown = {}

	for i = 1, gNumberOfKnobs do
		-- Blank the ring first, then install this dial's mode; the driver
		-- re-sends the (still zero) ring value in the new mode.
		events[#events + 1] =
			remote.make_midi(string.format("b0 %02x 00", gRingValueBase + i - 1))
		events[#events + 1] =
			remote.make_midi(string.format("b0 %02x %02x", gRingModeBase + i - 1, gRingModes[i]))
	end

	events[#events + 1] = remote.make_midi(string.format("b0 %02x 00", gSpeedDialRingValueCC))

	-- The page-row LEDs are deliberately NOT blanked here. An LED-off CC
	-- is byte-identical to "this switch is now off", and the loopback hands
	-- it straight back to this codec - as an absolute 0 on a value item it
	-- would switch off every mapped toggle on the focused channel (the
	-- first thing a blank does is un-mute whatever the page row points at).
	-- Reason's own state feedback paints the LEDs the moment the surface is
	-- prepared, so blanking buys nothing and risks the project.

	return events
end

--------------------------------------------------------------------------
-- remote_release_from_use  (Reason is closing: darken the surface)
--------------------------------------------------------------------------
function remote_release_from_use()
	local events = {}

	for i = 1, gNumberOfKnobs do
		events[#events + 1] =
			remote.make_midi(string.format("b0 %02x 00", gRingValueBase + i - 1))
	end

	events[#events + 1] = remote.make_midi(string.format("b0 %02x 00", gSpeedDialRingValueCC))

	-- Darken the page-row LEDs. The loopback echoes these CCs back into
	-- remote_process_midi(), but by now the mapping is released: the items
	-- are disabled, so Reason drops the echoed absolute 0 instead of
	-- switching anything off.
	for i = 0, 7 do
		events[#events + 1] = remote.make_midi(string.format("b0 %02x 00", gButtonCcBase + i))
	end

	return events
end

--------------------------------------------------------------------------
-- remote_set_state  (remember which device is focused)
--------------------------------------------------------------------------
function remote_set_state(changed_items)
	if remote.is_item_enabled(gScopeItemIndex) then
		gScope = remote.get_item_text_value(gScopeItemIndex)
	else
		gScope = ""
	end
end

--------------------------------------------------------------------------
-- remote_deliver_midi  (TEMPORARY diagnostic - remove once the master
-- scope is verified)
--
-- Reason calls this regularly and sends whatever events we return. We use
-- it to report the *active scope* to the driver trace on CC 119, which the
-- mapping does not use. The scope is queried live here rather than read
-- from gScope: remote_set_state() only refreshes gScope when an item
-- *value* changes, and a switch to a scope this map does not define
-- changes no item value, so it would be invisible (which is exactly the
-- case we are chasing).
--
--   d2 = 1  "Channel Strip"   - Reason Master Section is active
--   d2 = 2  "Channel"         - Reason Main Mixer Channel is active
--   d2 = 4  "Mixer 14:2"      - the Main Mixer *device* scope is active
--   d2 = 5  "Line Mixer 6:2"  - the Line Mixer device scope is active
--   d2 = 3  some other text this map maps _Scope for
--   d2 = 0  no scope of ours at all - Reason applied a scope this map does
--           not define, so nothing on the surface can work
--
-- Only sent when the value changes, so this is one line per lock/focus
-- change in the driver trace.
--------------------------------------------------------------------------
gLastReportedScope = nil

function remote_deliver_midi()
	local value = 0
	if remote.is_item_enabled(gScopeItemIndex) then
		local text = remote.get_item_text_value(gScopeItemIndex)
		if text == "Channel Strip" then
			value = 1
		elseif text == "Channel" then
			value = 2
		elseif text == "Mixer 14:2" then
			value = 4
		elseif text == "Line Mixer 6:2" then
			value = 5
		elseif text ~= "" then
			value = 3
		end
	end

	if value == gLastReportedScope then
		return {}
	end
	gLastReportedScope = value

	return { remote.make_midi(string.format("b0 77 %02x", value)) }
end

--------------------------------------------------------------------------
-- remote_process_midi  (dials, speed dial, crossfader, buttons)
--------------------------------------------------------------------------
function remote_process_midi(event)
	-- Relative encoders: dial CCs (CC16-23) and the Speed Dial (CC24).
	-- The byte is two's complement: 1..63 = clockwise, 65..127 = the other
	-- way. Declared as input="delta" items, so we hand Reason the signed
	-- delta and it does the accumulation and clamping.
	local ret = remote.match_midi("b? yy xx", event)
	if ret ~= nil then
		local delta = ret.x
		if delta > 63 then
			delta = delta - 128
		end
		delta = delta * gEncoderDirection

		local knob = gKnobCCLookup[ret.y]
		if knob ~= nil then
			remote.handle_input({
				time_stamp = event.time_stamp,
				item = gFirstKnobIndex + knob - 1,
				value = delta,
			})
			return true
		end

		if ret.y == gSpeedDialCC then
			remote.handle_input({
				time_stamp = event.time_stamp,
				item = gSpeedDialIndex,
				value = delta,
			})
			return true
		end

		-- The crossfader is an absolute 14-bit control (CC8 = MSB); the MSB
		-- alone already gives 128 positions, which is plenty for scrolling
		-- the channel window.
		if ret.y == gCrossfaderMSBCC then
			remote.handle_input({
				time_stamp = event.time_stamp,
				item = gCrossfaderIndex,
				value = ret.x,
			})
			return true
		end

		-- Switches: page row CC102-109, PermaBar CC110-117, speed dial
		-- click CC118. Anything not a switch falls through to the reserved
		-- block below.
		local item = gButtonCcLookup[ret.y]
		if item == nil and ret.y == gSpeedDialClickCC then
			item = gSpeedDialButtonIndex
		end

		if item ~= nil then
			local pressed = (ret.x ~= 0)
			if pressed and gButtonDown[item] then
				-- Duplicate press: this switch is already down, so this CC
				-- is the loopback echo of our own LED command (the LED CCs
				-- are the same CCs as the switch states), not a real second
				-- press.
				return true
			end
			gButtonDown[item] = pressed

			-- The page-row buttons are latching switches: the driver sends
			-- their STATE on every press - 127 = on, 0 = off - and nothing on
			-- release, so a value of 0 here means "switch it off", not
			-- "released". That is exactly what the value items in the item
			-- table are for. Page -/+ and the Speed Dial click are triggers,
			-- so they keep the press/release encoding a "button" item wants.
			local value
			if item >= gFirstButtonIndex and item < gFirstButtonIndex + gNumberOfKnobs then
				value = pressed and ret.x or 0
			else
				value = pressed and 1 or 0
			end

			remote.handle_input({
				time_stamp = event.time_stamp,
				item = item,
				value = value,
			})
			return true
		end

		-- Touch strips and the crossfader LSB have no mapping yet: consume
		-- them so nothing leaks into Reason, but do not drive any item.
		if ret.y == gCrossfaderLSBCC
			or ret.y == gSpeedDialTouchCC
			or ret.y == gCrossfaderTouchCC
			or (ret.y >= gEncoderTouchBase and ret.y < gEncoderTouchBase + gNumberOfKnobs) then
			return true
		end

		return false
	end

	return false
end
