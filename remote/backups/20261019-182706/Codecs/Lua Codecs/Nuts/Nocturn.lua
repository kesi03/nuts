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
		Button 1..8 (green LEDs)     notes 0-7              Button 1..8
		PermaBar Page -/+            notes 10/11            Page Left/Right
		Speed Dial                   CC24, relative         Speed Dial
		Speed Dial click             note 81                Speed Dial Button
		Crossfader                   CC8 (MSB), CC9 (LSB)   Crossfader
		Crossfader touch             CC89                   (reserved)

		Codec -> device (feedback):  CC32-39 knob ring values 0-11,
		                             CC40 speed dial ring value 0-11,
		                             CC48-55 knob ring modes 0-5,
		                             notes 0-7 button LEDs.

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

-- Note -> item index. Button presses arrive as notes on channel 1: notes 0-7
-- are the 8 page-row buttons (green LEDs), notes 8-15 the PermaBar (red LEDs)
-- in surface order Learn, View, Page-, Page+, User, FX, INST, MIXER. Only the
-- page-row buttons and Page -/+ are given items for now - the remaining
-- PermaBar buttons are deliberately left unmapped.
gButtonNoteLookup = {
	[0]=10, [1]=11, [2]=12, [3]=13, [4]=14, [5]=15, [6]=16, [7]=17,
	[10]=18, -- Page Left  (PermaBar index 10)
	[11]=19, -- Page Right (PermaBar index 11)
}

gSpeedDialNote = 81  -- Speed Dial click (the only "press" on the speed dial)

-- Which buttons are physically down, keyed by item index. The loopback hands
-- every client the messages written by every other client, so Reason's own
-- button-LED notes (the same notes as the presses) come back in through the
-- In Port as a second press and would toggle a mapped switch twice. A real
-- button must be released before it can be pressed again, so a repeat "down"
-- while this flag is set can only be that echo.
gButtonDown = {}

-- Codec -> device LED addresses.
gRingValueBase        = 0x20  -- CC32-39: knob ring values 0-11
gSpeedDialRingValueCC = 0x28  -- CC40:    speed dial ring value 0-11
gRingModeBase         = 0x30  -- CC48-55: knob ring modes 0-5
gButtonNoteBase       = 0x00  -- notes 0-7: page-row button LEDs

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

		-- Page-row buttons, above the dials (green LEDs). They drive their
		-- item and light from Reason's feedback (x="127*value" below).
		{name="Button 1", input="button", output="value"},
		{name="Button 2", input="button", output="value"},
		{name="Button 3", input="button", output="value"},
		{name="Button 4", input="button", output="value"},
		{name="Button 5", input="button", output="value"},
		{name="Button 6", input="button", output="value"},
		{name="Button 7", input="button", output="value"},
		{name="Button 8", input="button", output="value"},

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

	for i = 1, 8 do
		outputs[#outputs + 1] = {
			name = "Button " .. i,
			pattern = string.format("90 %02x xx", gButtonNoteBase + i - 1),
			x = "127*value",
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

	for i = 0, 7 do
		events[#events + 1] = remote.make_midi(string.format("90 %02x 00", gButtonNoteBase + i))
	end

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

	for i = 0, 7 do
		events[#events + 1] = remote.make_midi(string.format("90 %02x 00", gButtonNoteBase + i))
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

	-- Buttons (page-row notes 0-7, PermaBar Page -/+ notes 10/11) and the
	-- Speed Dial click arrive as notes on channel 1. ret.x = 1 for note-on,
	-- 0 for note-off (note-on with velocity 0 counts as note-off).
	ret = remote.match_midi("<100x>? yy zz", event)
	if ret ~= nil then
		local item = gButtonNoteLookup[ret.y]
		if item == nil and ret.y == gSpeedDialNote then
			item = gSpeedDialButtonIndex
		end

		if item ~= nil then
			local value = (ret.x ~= 0 and ret.z > 0) and 1 or 0
			if value == 1 and gButtonDown[item] then
				-- Duplicate press: the button is already down, so this is
				-- the loopback echo, not a real second press.
				return true
			end
			gButtonDown[item] = (value == 1)
			remote.handle_input({
				time_stamp = event.time_stamp,
				item = item,
				value = value,
			})
			return true
		end
	end

	return false
end
