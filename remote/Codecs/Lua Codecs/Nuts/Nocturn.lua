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

	The surface has pages: the 8 dials and the 8 page-row buttons BANK, and a
	page is a group of parameters on those same physical controls (the four
	pages are the four sections of a Reason mixer channel). The DRIVER owns
	the banking (src/Nuts.Driver/Midi/PageModel.cs): the same physical dial or
	switch sends a different CC per page, the driver steps pages from the
	PermaBar and tells this codec which page is live on CC 119. Page -/+ and
	the four page-jump switches never reach Reason, so paging lives entirely
	on the driver side and this codec only has to know which CCs belong to
	the active page.

	Because a .remotemap binds one item to exactly one remotable per scope,
	each page's dials and buttons are SEPARATE ITEMS: "Knob 1 P1" ..
	"Knob 8 P4", "Button 1 P1" .. "Button 8 P4". The map gives each its own
	parameters, and the driver's per-page CCs select the item - Reason is
	never told that a page changed. This is the same technique the Akai MPK
	Mini Play codec uses for its banks ("Knob 1 A" / "Knob 1 B").

	The item names are deliberately GENERIC: P1..P4 are the driver's four
	page slots, not the four sections of any one device. The scope decides
	what a page means - the mixer scope fills P1..P4 with the channel's
	Mixer/Dynamics/EQ/FX sections, another scope fills them with whatever
	its own pages are - so one codec serves every scope and only the
	.remotemap changes.

	Everything else is shared across pages: the Speed Dial, its click and
	touch, the crossfader, the ring values/modes and the PermaBar.

	MIDI assignment table (driver-side defaults, verified by live capture):

		Control                      MIDI (channel 1)       Item
		-------------------------    -------------------    ------------------
		Dial 1..8                    CC per page, relative  Knob 1..8 P<n>
		Dial 1..8 touch              CC80-87                (reserved)
		Button 1..8 (green LEDs)     CC per page, state     Button 1..8 P<n>
		PermaBar Page -/+            CC110/111              (driver: paging)
		PermaBar MIX/USER/INSTR/FX   CC115/112/114/113      (driver: page jumps)
		Speed Dial                   CC24, relative         Speed Dial
		Speed Dial click             CC118                  Speed Dial Button
		Crossfader                   CC8 (MSB), CC9 (LSB)   Crossfader
		Crossfader touch             CC89                   (reserved)
		Page echo (driver -> codec)  CC119, page number     (consumed here)

		Codec -> device (feedback):  CC32-39 knob ring values 0-11,
		                             CC40 speed dial ring value 0-11,
		                             CC48-55 knob ring modes 0-5,
		                             the active page's button-LED CCs (0/127).

	Notes
	-----
	- These numbers are a three-way contract: src/Nuts.Driver/appsettings.json
	  (Midi:Mapping and Midi:Paging), remote/mapping/nocturn-controls.json and
	  the lookup tables below. Change all three together.
	- The page CC tables below (gKnobCCByPage / gButtonCCByPage) mirror
	  Midi:Paging:EncoderCcs and Midi:Paging:ButtonCcs in the driver's
	  appsettings.json, page for page.
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
	- The ring modes are per page and owned by the driver
	  (Midi:Paging:RingModes): it repaints them on every page change, since
	  one page can want a different shape on the same dial (the FX page has
	  centre-anchored insert rotaries next to fill-style send levels).
	  gRingModes here is only the placeholder remote_prepare_for_use() uses
	  before the driver's first page echo arrives.
]]

--------------------------------------------------------------------------
-- Item indices (1-based, in remote.define_items() order below)
--------------------------------------------------------------------------
-- The dials and buttons exist once per page (see remote_init), so their
-- indices are computed from the page rather than being fixed constants.
-- Layout: 1 _Scope, 2 Page, then per page in order: 8 knobs, 8 buttons.
gScopeItemIndex   = 1   -- _Scope
gPageItemIndex    = 2   -- Page
gNumberOfKnobs    = 8
gFirstKnobIndex   = 3   -- page 1: Knob 1..8   -> 3..10
gItemsPerPage     = 16  -- 8 knobs + 8 buttons
gNextAfterPages   = 67  -- first index after _Scope, Page and the 4 page blocks

-- First item index of a page's Knob 1. gFirstButtonIndex + n - 1 is Button n.
function gFirstKnobIndexOf(page)
	return gFirstKnobIndex + (page - 1) * gItemsPerPage
end

function gFirstButtonIndexOf(page)
	return gFirstKnobIndexOf(page) + gNumberOfKnobs
end

-- The shared, unbanked items sit after the page blocks.
gSpeedDialIndex       = gNextAfterPages
gSpeedDialButtonIndex = gNextAfterPages + 1
gCrossfaderIndex      = gNextAfterPages + 2

--------------------------------------------------------------------------
-- MIDI <-> control lookup tables
--------------------------------------------------------------------------
-- PAGES. Only the dials (1-8) and the page-row buttons (1-8) bank; everything
-- else - speed dial, its click and touch, the crossfader, the touches, the
-- ring values/modes, the PermaBar - is shared and keeps one CC. The driver
-- banks the CCs (see src/Nuts.Driver/Midi/PageModel.cs) and tells us which
-- page is live on CC 119; we pick the matching column out of these tables.
--
-- The driver's page tables are the source of truth. These numbers must match
-- Midi:Paging:EncoderCcs / Midi:Paging:ButtonCcs in the driver's
-- appsettings.json, and the page names must match Midi:Paging:Names.
--
-- The NAMES are the driver's own slot labels - for the mixer channel they
-- are the four sections (Mixer, Dynamics, EQ, FX), but they are only
-- informational. The ITEMS are named "Knob n P<n>" / "Button n P<n>", so a
-- scope's .remotemap can put any parameters it likes into any of the four
-- slots; the slot a section occupies is the scope's business, not ours.
gPageNames = { "Mixer", "Dynamics", "EQ", "FX" }
gPageCount = 4

-- Per page: CC -> dial number (1-8). Relative encoders. The item index is
-- then gFirstKnobIndexOf(gCurrentPage) + dial - 1, so the same table works
-- whichever page is live.
gKnobCCByPage = {
	{ [0x10]=1, [0x11]=2, [0x12]=3, [0x13]=4, [0x14]=5, [0x15]=6, [0x16]=7, [0x17]=8 }, -- page 1 Mixer
	{ [0x38]=1, [0x39]=2, [0x3a]=3, [0x3b]=4, [0x3c]=5, [0x3d]=6, [0x3e]=7, [0x3f]=8 }, -- page 2 Dynamics
	{ [0x48]=1, [0x49]=2, [0x4a]=3, [0x4b]=4, [0x4c]=5, [0x4d]=6, [0x4e]=7, [0x4f]=8 }, -- page 3 EQ
	{ [0x00]=1, [0x01]=2, [0x02]=3, [0x03]=4, [0x04]=5, [0x05]=6, [0x06]=7, [0x07]=8 }, -- page 4 FX
}

-- Per page: CC -> button number (1-8) for the page-row switches.
gButtonCCByPage = {
	{ [0x66]=1, [0x67]=2, [0x68]=3, [0x69]=4, [0x6a]=5, [0x6b]=6, [0x6c]=7, [0x6d]=8 }, -- Mixer
	{ [0x40]=1, [0x41]=2, [0x42]=3, [0x43]=4, [0x44]=5, [0x45]=6, [0x46]=7, [0x47]=8 }, -- Dynamics
	{ [0x5a]=1, [0x5b]=2, [0x5c]=3, [0x5d]=4, [0x5e]=5, [0x5f]=6, [0x60]=7, [0x61]=8 }, -- EQ
	{ [0x19]=1, [0x1a]=2, [0x1b]=3, [0x1c]=4, [0x1d]=5, [0x1e]=6, [0x1f]=7, [0x29]=8 }, -- FX
}

-- The active page, 1-based. Set from the driver's page echo (CC 119) and kept
-- across calls; remote_prepare_for_use() assumes page 1 until the echo lands.
gCurrentPage = 1

gPageEchoCC = 0x77  -- CC119: driver -> codec page echo (page number 1-based)

-- Page-aware lookups. Every table above is indexed by the driver's 1-based
-- page number, so a bogus page echo can never index off the end. A dial or
-- button CC resolves to the control's NUMBER on the active page; the caller
-- turns that into an item index with gFirstKnobIndexOf / gFirstButtonIndexOf.
function gKnobNumberForCC(cc)
	local page = gKnobCCByPage[gCurrentPage] or gKnobCCByPage[1]
	return page[cc]
end

function gButtonNumberForCC(cc)
	local page = gButtonCCByPage[gCurrentPage] or gButtonCCByPage[1]
	return page[cc]
end

gSpeedDialCC       = 0x18  -- CC24, relative (same encoding as the dials)
gCrossfaderMSBCC   = 0x08  -- CC8  = crossfader MSB
gCrossfaderLSBCC   = 0x09  -- CC9  = crossfader LSB (unused)
gEncoderTouchBase  = 0x50  -- CC80-87: dial touch (127 down / 0 up), reserved
gSpeedDialTouchCC  = 0x58  -- CC88
gCrossfaderTouchCC = 0x59  -- CC89

-- PermaBar switches: the same CCs on every page. Page -/+ and the four page
-- jumps are consumed by the DRIVER, not forwarded, so they are deliberately
-- absent here - the driver owns paging. Only the speed dial click is a
-- PermaBar-adjacent switch this codec still maps.
gSpeedDialClickCC = 0x76  -- CC118: Speed Dial click (the only "press" on it)

-- Which switches are physically down, keyed by "page:item". The loopback hands
-- every client the messages written by every other client, so Reason's own
-- button-LED CCs (the same CCs as the switch states) come back in through the
-- In Port as a second press and would toggle a mapped switch twice. A real
-- button must be released before it can be pressed again, so a repeat "down"
-- while this flag is set can only be that echo. Keyed by page because the same
-- physical switch is a different item on each page.
gButtonDown = {}

-- Codec -> device LED addresses (sent to the driver over the loopback; the
-- driver turns them into the hardware's own LED commands). Shared: ring values
-- and modes do not bank, so page changes are handled by the driver blanking
-- them and the codec resending the new page's values (see remote_set_state).
gRingValueBase        = 0x20  -- CC32-39: knob ring values 0-11
gSpeedDialRingValueCC = 0x28  -- CC40:    speed dial ring value 0-11
gRingModeBase         = 0x30  -- CC48-55: knob ring modes 0-5

-- Set to -1 if the dials feel inverted on your unit. Both the hardware and
-- the driver forward the raw two's-complement byte; this only flips the
-- interpretation, so it is a one-line fix without touching the driver.
gEncoderDirection = 1

-- Fallback ring modes used only if the driver never sends a per-page mode.
-- The driver owns the real per-page table (Midi:Paging:RingModes) and
-- repaints on every page change; this just keeps remote_prepare_for_use()
-- honest before the first echo.
gRingModes = { 0, 0, 0, 0, 0, 0, 0, 0 }

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
	}

	-- One dial set and one button set PER PAGE, named "Knob n P<page>" /
	-- "Button n P<page>" - the same idiom as the Akai MPK Mini Play codec's
	-- "Knob 1 A" / "Knob 1 B". A .remotemap maps one item to exactly one
	-- remotable per scope, so four different parameter sets on the same
	-- physical dial require four items: there is no way to re-point one
	-- item from outside Reason. The driver's per-page CCs select the item
	-- without Reason ever being told a page changed.
	--
	-- P1..P4 are the driver's page SLOTS, not a device's page names: the
	-- scope's .remotemap decides what each slot means, so the same codec
	-- works for every scope.
	local pageCount = gPageCount

	items[#items + 1] = { name = "Page", output = "text" }

	for page = 1, pageCount do
		-- Endless encoders: input="delta" lets Reason accumulate the
		-- two's-complement delta we hand it in remote_process_midi().
		for n = 1, gNumberOfKnobs do
			items[#items + 1] =
				{ name = string.format("Knob %d P%d", n, page),
				  input = "delta", output = "value", min = 0, max = 127 }
		end

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
		for n = 1, gNumberOfKnobs do
			items[#items + 1] =
				{ name = string.format("Button %d P%d", n, page),
				  input = "value", output = "value", min = 0, max = 127 }
		end
	end

	-- Page -/+ and the four page jumps are NOT items: the driver consumes
	-- those switches to drive paging and never forwards them, so Reason
	-- must not map them. Paging is driver state, not a Reason remotable.
	items[#items + 1] = {name="Speed Dial", input="delta", output="value", min=0, max=127}
	items[#items + 1] = {name="Speed Dial Button", input="button"}
	items[#items + 1] = {name="Crossfader", input="value", output="value", min=0, max=127}

	remote.define_items(items)

	-- ------------------------------------------------------------------
	-- AUTO INPUTS - REQUIRED so Reason routes the port into this codec.
	-- ------------------------------------------------------------------
	-- Reason delivers those messages that match a registered auto-input to
	-- the codec; remote_process_midi() is an ADDITIONAL manual hook, not a
	-- substitute for it. Every factory codec declares auto-inputs (all 76 of
	-- them; AkaiLPD8, MPK Mini Play, Launchkey, AlphaTrack, mackiecodec...),
	-- and the Akai codec's own comment on a non-matching CC is "not a knob;
	-- let the auto-inputs handle it". Without this block Reason matches no
	-- message at all: the surface is silent and nothing responds, because
	-- remote_process_midi() is never called.
	--
	-- The page-aware re-routing still happens in remote_process_midi(): it
	-- recomputes the item index from gCurrentPage and calls handle_input(),
	-- which overrides whatever item the pattern below named. The item named
	-- here is therefore only a routing target - it keeps Reason's matcher
	-- armed - and is deliberately the SHARED item wherever one exists, so a
	-- stray unclaimed message can never move a banked parameter.
	--
	-- Patterns, in the codec's own idiom ("b0 <cc> xx"): the dials and the
	-- speed dial are relative (delta items); the crossfader is absolute
	-- (value item, MSB only - 128 positions is plenty); the switches carry
	-- their state (value items driven from the driver's toggle latch).
	local inputs = {}

	-- Banked dials. One pattern per page's CC -> that page's Knob 1 item.
	-- remote_process_midi() re-points it at the active page, so naming page
	-- 1's item here is only about routing.
	for page = 1, gPageCount do
		local firstKnob = gFirstKnobIndexOf(page)
		for cc, n in pairs(gKnobCCByPage[page]) do
			inputs[#inputs + 1] = {
				pattern  = string.format("b0 %02x xx", cc),
				name     = string.format("Knob %d P%d", n, page),
				value    = "x",
			}
		end
	end

	-- Speed Dial (shared, CC24): delta item, mapped directly.
	inputs[#inputs + 1] = {
		pattern = string.format("b0 %02x xx", gSpeedDialCC),
		name    = "Speed Dial",
		value   = "x",
	}

	-- Banked page-row switches. One pattern per page's CC, naming that
	-- page's Button 1-style item; remote_process_midi() re-points it.
	for page = 1, gPageCount do
		for cc, n in pairs(gButtonCCByPage[page]) do
			inputs[#inputs + 1] = {
				pattern = string.format("b0 %02x xx", cc),
				name    = string.format("Button %d P%d", n, page),
				value   = "x",
			}
		end
	end

	-- Speed Dial click (shared, CC118): trigger, button item.
	inputs[#inputs + 1] = {
		pattern = string.format("b0 %02x xx", gSpeedDialClickCC),
		name    = "Speed Dial Button",
		value   = "x ~= 0 and 1 or 0",
	}

	-- Crossfader (shared, CC8 MSB): absolute value item.
	inputs[#inputs + 1] = {
		pattern = string.format("b0 %02x xx", gCrossfaderMSBCC),
		name    = "Crossfader",
		value   = "x",
	}

	-- The driver's page echo (CC119) is consumed in remote_process_midi and
	-- maps no item, so it gets no auto-input.

	remote.define_auto_inputs(inputs)

	-- LED feedback. Item value 0-127 -> 0-11 ring segments (the driver clamps
	-- to 11) or 0/127 for the button LEDs.
	local outputs = {}

	-- Rings do NOT bank: there are only 8 ring CCs and all four pages' knobs
	-- share them. Each page's knob therefore gets an output on the same CC,
	-- and only the current page's item is ever moved by Reason, so the four
	-- definitions cannot fight. The driver holds one ring cache, which is
	-- also why a page change blanks the rings until the new page repaints.
	for page = 1, gPageCount do
		for n = 1, gNumberOfKnobs do
			outputs[#outputs + 1] = {
				name = string.format("Knob %d P%d", n, page),
				pattern = string.format("b0 %02x 0<00xx>", gRingValueBase + n - 1),
				x = "value*11/127",
			}
		end
	end

	outputs[#outputs + 1] = {
		name = "Speed Dial",
		pattern = string.format("b0 %02x 0<00xx>", gSpeedDialRingValueCC),
		x = "value*11/127",
	}

	-- The button LEDs are value items with min 0 max 127, so Reason's
	-- feedback arrives as 0 or 127 and the CC value is that value directly.
	--
	-- One item per page means one output per page item, each on that page's
	-- own CC. Nothing has to be filtered here: Reason only sends feedback for
	-- items its map actually drives, and the driver resolves an incoming LED
	-- CC against the active page's table. So a page that is not current
	-- simply never has its item moved.
	for page = 1, gPageCount do
		local ccByNumber = {}
		for cc, number in pairs(gButtonCCByPage[page]) do
			ccByNumber[number] = cc
		end

		for n = 1, gNumberOfKnobs do
			outputs[#outputs + 1] = {
				name = string.format("Button %d P%d", n, page),
				pattern = string.format("b0 %02x 0<00xx>", ccByNumber[n]),
				x = "value",
			}
		end
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

	-- Darken the page-row LEDs on every page's CCs. The loopback echoes these
	-- back into remote_process_midi(), but by now the mapping is released:
	-- the items are disabled, so Reason drops the echoed absolute 0 instead
	-- of switching anything off.
	for page = 1, gPageCount do
		for _, cc in pairs(gButtonCCByPage[page]) do
			events[#events + 1] = remote.make_midi(string.format("b0 %02x 00", cc))
		end
	end

	return events
end

--------------------------------------------------------------------------
-- remote_set_state  (remember which device is focused, and the live page)
--------------------------------------------------------------------------
function remote_set_state(changed_items)
	if remote.is_item_enabled(gScopeItemIndex) then
		gScope = remote.get_item_text_value(gScopeItemIndex)
	else
		gScope = ""
	end

	-- The Page item is a text output. Nothing on the surface shows it (the
	-- unit has no display) and no scope binds it today, so it stays empty;
	-- it exists so the page is visible in Reason and in the driver trace, and
	-- to give the LED work that comes later something to read.
	-- gCurrentPage itself comes from the echo in remote_process_midi(); this
	-- is a readback, not the source.
	gPageName = string.format("P%d", gCurrentPage)
end

--------------------------------------------------------------------------
-- remote_deliver_midi
--
-- The driver's page echo (CC 119) is consumed in remote_process_midi(), so
-- nothing has to be sent from here yet. This hook stays in place for the
-- LED/context work that comes after the channel strip is verified (the
-- focused device is available as gScope, refreshed in remote_set_state).
--------------------------------------------------------------------------
function remote_deliver_midi()
	return {}
end

--------------------------------------------------------------------------
-- remote_process_midi  (dials, speed dial, crossfader, buttons)
--------------------------------------------------------------------------
function remote_process_midi(event)
	-- Relative encoders: the active page's dial CCs (see gKnobCCByPage) and
	-- the Speed Dial (CC24). The byte is two's complement: 1..63 = clockwise,
	-- 65..127 = the other way. Declared as input="delta" items, so we hand
	-- Reason the signed delta and it does the accumulation and clamping.
	local ret = remote.match_midi("b? yy xx", event)
	if ret ~= nil then
		local delta = ret.x
		if delta > 63 then
			delta = delta - 128
		end
		delta = delta * gEncoderDirection

		local knob = gKnobNumberForCC(ret.y)
		if knob ~= nil then
			remote.handle_input({
				time_stamp = event.time_stamp,
				item = gFirstKnobIndexOf(gCurrentPage) + knob - 1,
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

		-- The driver's page echo (CC119): tells us which page is live so the
		-- banking lookups above/below pick the right table. Not forwarded to
		-- Reason - it maps no item - and consumed here.
		if ret.y == gPageEchoCC then
			local page = ret.x
			if page >= 1 and page <= gPageCount and page ~= gCurrentPage then
				gCurrentPage = page
				-- Latches belong to the page they were pressed on; forget
				-- them all so a switch held across a page change cannot
				-- block its counterpart on the new page.
				gButtonDown = {}
			end
			return true
		end

		-- Switches: the page's page-row CCs, then the shared speed dial click.
		-- The PermaBar Page -/+ and page jumps never reach us: the driver
		-- consumes them to drive paging.
		local button = gButtonNumberForCC(ret.y)
		local item = nil
		if button ~= nil then
			item = gFirstButtonIndexOf(gCurrentPage) + button - 1
		elseif ret.y == gSpeedDialClickCC then
			item = gSpeedDialButtonIndex
		end

		if item ~= nil then
			local pressed = (ret.x ~= 0)
			local latchKey = gCurrentPage .. ":" .. item
			if pressed and gButtonDown[latchKey] then
				-- Duplicate press: this switch is already down, so this CC
				-- is the loopback echo of our own LED command (the LED CCs
				-- are the same CCs as the switch states), not a real second
				-- press.
				return true
			end
			gButtonDown[latchKey] = pressed

			-- The page-row buttons are latching switches: the driver sends
			-- their STATE on every press - 127 = on, 0 = off - and nothing on
			-- release, so a value of 0 here means "switch it off", not
			-- "released". That is exactly what the value items in the item
			-- table are for. The Speed Dial click is a trigger, so it keeps
			-- the press/release encoding a "button" item wants.
			local value
			if button ~= nil then
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
