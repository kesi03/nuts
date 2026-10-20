using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Nuts.Driver.Config;
using Nuts.Driver.Led;
using Nuts.Driver.Protocol;
using Nuts.Driver.Services;
using Windows.Devices.Midi2;
using Windows.Devices.Midi2.Enumeration;
using Windows.Devices.Midi2.Transports.BasicLoopback;

namespace Nuts.Driver.Midi;

/// <summary>
/// DAW bridge over Windows MIDI Services (Milestone 2). Connects to a
/// persistent basic-loopback endpoint (default name "Nocturn") and:
/// <list type="bullet">
/// <item>sends surface input as MIDI 1.0 channel-voice UMP words
/// (docs/midi-mapping.md; numbers configurable via Midi:Mapping), which
/// any DAW listening on that endpoint receives — Reason 10 sees the port
/// through WinMM (verified 2026-10-19);</item>
/// <item>receives CC messages from the DAW and drives the surface LEDs
/// via the <see cref="ILedManager"/> cache.</item>
/// </list>
/// The loopback endpoint is created on the fly when missing (transient
/// endpoints do not survive a MIDI service restart, and no configuration
/// file is registered on this PC).
/// </summary>
public sealed class MidiBridgeService : BackgroundService
{
    private readonly NocturnListenerService _listener;
    private readonly ILedManager _leds;
    private readonly MidiOptions _options;
    private readonly MidiMapping _mapping;
    private readonly ButtonLogic _buttons;
    private readonly ILogger<MidiBridgeService> _log;

    // Last state applied from DAW messages, so partial updates (value
    // without mode, or mode without value) can be recombined. Guarded by
    // _ringGate: the MIDI callback writes them, a page change overwrites
    // them from the page table.
    private readonly object _ringGate = new();
    private readonly RingMode[] _ringModes = new RingMode[NocturnProtocol.EncoderCount];
    private readonly byte[] _ringValues = new byte[NocturnProtocol.EncoderCount];

    private MidiSession? _session;
    private MidiEndpointConnection? _connection;

    public MidiBridgeService(
        NocturnListenerService listener,
        ILedManager leds,
        DriverOptions options,
        ILogger<MidiBridgeService> log)
    {
        _listener = listener;
        _leds = leds;
        _options = options.Midi;
        _mapping = new MidiMapping(options.Midi.Mapping, options.Midi.Paging);
        _buttons = new ButtonLogic(_mapping, options.Midi.Mapping, leds);
        _log = log;
        _listener.InputReceived += OnInput;
        _log.LogInformation("Button kinds: {Kinds}.", _buttons.Describe());
        _log.LogInformation("{Pages}", _mapping.Pages.Describe());

        if (_options.Enabled && _mapping.Pages.PageCount > 1)
            _log.LogInformation("Active {Pages}.", _mapping.Pages.DescribeCurrent());
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        if (!_options.Enabled)
        {
            _log.LogInformation("MIDI bridge disabled (Midi:Enabled = false).");
            return;
        }

        while (!ct.IsCancellationRequested)
        {
            try
            {
                Run(ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                _log.LogError(ex, "MIDI bridge error; retrying in 5s.");
            }
            finally
            {
                Teardown();
            }

            try
            {
                await Task.Delay(TimeSpan.FromSeconds(5), ct);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }

        Teardown();
    }

    private void Run(CancellationToken ct)
    {
        _session = MidiSession.Create(_options.SessionName);
        _log.LogInformation("MIDI session '{Name}' created.", _options.SessionName);

        var endpoint = FindEndpoint() ?? CreateLoopbackEndpoint(ct);
        if (endpoint is null)
        {
            _log.LogError(
                "MIDI endpoint '{Name}' not found and could not be created. " +
                "Install the Windows MIDI Services Transports package " +
                "(github.com/microsoft/MIDI releases) or create the loopback manually: " +
                "'midi basic-loopback create -n {Name} -s'.",
                _options.EndpointName, _options.EndpointName);
            ct.WaitHandle.WaitOne(TimeSpan.FromSeconds(60));
            return;
        }

        _connection = _session.CreateEndpointConnection(
            endpoint.EndpointDeviceId,
            new MidiEndpointConnectionSettings(
                waitForEndpointReceiptOnSend: false, autoReconnect: true));
        _connection.MessageReceived += OnMessage;
        _connection.EndpointDeviceDisconnected += OnDisconnected;
        _connection.EndpointDeviceReconnected += OnReconnected;

        if (!_connection.Open())
        {
            _log.LogError("Failed to open MIDI connection to '{Name}'.", endpoint.Name);
            return;
        }

        _log.LogInformation(
            "Connected to MIDI endpoint '{Name}' ({Id}).",
            endpoint.Name, endpoint.EndpointDeviceId);

        // Paint the active page's rings and indicator, then tell the DAW
        // which page is live. Sent on every (re)connect because a codec that
        // loads after the driver, or a Reason restart, would otherwise keep
        // whatever page it last knew about.
        PaintPageIndicators(_mapping.Pages.Current);
        SendPageEcho(_mapping.Pages.Current);

        // Stay alive until shutdown; AutoReconnect keeps the pipe up across
        // service restarts.
        ct.WaitHandle.WaitOne();
    }

    /// <summary>
    /// Applies the page's ring modes and lights the jump button for the
    /// page that is active. Ring values are left alone - they belong to the
    /// DAW and arrive when it repaints.
    /// </summary>
    private void PaintPageIndicators(int page)
    {
        lock (_ringGate)
        {
            for (var encoder = 0; encoder < NocturnProtocol.EncoderCount; encoder++)
            {
                _ringModes[encoder] = _mapping.Pages.RingModeFor(page, encoder);
                _ringValues[encoder] = 0;
                _leds.SetRing(encoder, _ringModes[encoder], 0);
            }
        }

        for (var i = 0; i < _mapping.Pages.JumpButtons.Count; i++)
            _leds.SetButtonLed(
                _mapping.Pages.JumpButtons[i], i == page ? LedState.On : LedState.Off);
    }

    private MidiEndpointDeviceInformation? FindEndpoint()
    {
        foreach (var info in MidiEndpointDeviceInformation.FindAll())
        {
            if (string.Equals(info.Name, _options.EndpointName, StringComparison.OrdinalIgnoreCase))
                return info;
        }

        return null;
    }

    private MidiEndpointDeviceInformation? CreateLoopbackEndpoint(CancellationToken ct)
    {
        if (!_options.CreateLoopbackIfMissing)
            return null;

        if (!MidiBasicLoopbackManager.IsTransportAvailable)
        {
            _log.LogError("The MIDI 1.0 basic loopback transport is not available on this PC.");
            return null;
        }

        _log.LogInformation(
            "Creating basic loopback endpoint '{Name}'...", _options.EndpointName);
        var response = MidiBasicLoopbackManager.CreateTransientLoopback(
            new MidiBasicLoopbackCreationConfig(
                new MidiBasicLoopbackEndpointDefinition(
                    _options.EndpointName, "nuts driver <-> DAW"))
            {
                FeedbackProtection = MidiBasicLoopbackFeedbackProtection.Mute,
            });

        if (!response.Success)
        {
            _log.LogError(
                "Loopback creation failed: {Code} {Message}",
                response.ErrorCode, response.ErrorMessage);
            return null;
        }

        // The device node appears asynchronously; give the service a moment.
        for (var i = 0; i < 20 && !ct.IsCancellationRequested; i++)
        {
            var found = FindEndpoint();
            if (found is not null)
                return found;
            Thread.Sleep(250);
        }

        return null;
    }

    private void OnInput(InputEvent ev)
    {
        var connection = _connection;
        if (connection is not { IsOpen: true })
            return;

        Span<uint> words = stackalloc uint[2];
        var count = ev.Kind == InputEventKind.Button && ev.Index < NocturnProtocol.ButtonCount
            ? MapButtonInput(ev, words)
            : _mapping.MapInput(ev, words);
        for (var i = 0; i < count; i++)
        {
            var result = connection.SendSingleMessageWords(0, words[i]);
            if (MidiEndpointConnection.SendMessageFailed(result))
                _log.LogWarning("MIDI send failed: {Result}", result);
        }
    }

    /// <summary>
    /// Buttons go through <see cref="ButtonLogic"/> rather than straight
    /// through the mapping: the button's kind decides whether the press
    /// becomes a CC at all (a toggle button's release does not) and with
    /// which value.
    ///
    /// Page switches are consumed here instead of being forwarded: the DAW
    /// has no idea the surface has pages, so a page press changes the driver's
    /// own page state and the driver repaints the surface itself.
    /// </summary>
    private int MapButtonInput(InputEvent ev, Span<uint> words)
    {
        if (_mapping.Pages.IsInternalButton(ev.Index))
        {
            // Jump buttons go straight to their page; the step buttons move
            // one on, wrapping. Only the press edge acts - holding a step
            // button must not page through every page.
            if (ev.Value == 0)
                return 0;

            var jump = _mapping.Pages.PageOfJumpButton(ev.Index);
            var page = jump >= 0
                ? jump
                : ev.Index == _mapping.Pages.PrevButton ? _mapping.Pages.Current - 1
                : _mapping.Pages.Current + 1;

            SwitchPage(((page % _mapping.Pages.PageCount) + _mapping.Pages.PageCount)
                % _mapping.Pages.PageCount);
            return 0;
        }

        if (!_buttons.TryHandleInput(ev.Index, ev.Value != 0, out var word))
            return 0;

        words[0] = word;
        return 1;
    }

    /// <summary>
    /// Makes a page active and repaints everything that page owns: the
    /// banked switches (each restores its own latched state, not the page
    /// we came from), the encoder rings (modes from the page's table, values
    /// blank until the DAW sends the new page's), and the page indicator on
    /// the jump buttons. Then tells the DAW which page is live so its codec
    /// can follow.
    /// </summary>
    private void SwitchPage(int page)
    {
        if (!_mapping.Pages.TrySetPage(page, out var previous))
            return;

        _buttons.RepaintPage(page);
        PaintPageIndicators(page);
        SendPageEcho(page);
        _log.LogInformation(
            "Page {From} -> {To} ({Pages}).", previous + 1, page + 1, _mapping.Pages.DescribeCurrent());
    }

    /// <summary>
    /// Tells the DAW which page is active (1-based), so a page-aware codec
    /// can select the right item table. Sent on every page change and once
    /// on connect, so a codec that loaded after the driver still learns it.
    /// </summary>
    private void SendPageEcho(int page)
    {
        var connection = _connection;
        if (connection is not { IsOpen: true })
            return;

        if (_mapping.Pages.PageCount <= 1)
            return;

        var word = MidiMapping.ChannelVoice(0xB0, _mapping.Pages.EchoCc, (byte)(page + 1));
        var result = connection.SendSingleMessageWords(0, word);
        if (MidiEndpointConnection.SendMessageFailed(result))
            _log.LogWarning("MIDI send failed: {Result}", result);
    }

    private void OnMessage(IMidiMessageReceivedEventSource sender, MidiMessageReceivedEventArgs args)
    {
        var wordCount = args.FillWords(out var word0, out _, out _, out _);
        if (wordCount == 0 || !MidiMapping.TryDecodeChannelVoice(word0, out var status, out var d1, out var d2))
            return;

        _log.LogDebug("MIDI in: status 0x{Status:X2} d1 {Data1} d2 {Data2}", status, d1, d2);

        switch (status & 0xF0)
        {
            // Button-LED CC (the same CCs the switches themselves send, so a
            // press lights the button even before the DAW answers). The DAW's
            // word is the truth for both the latch and the LED, so a
            // host-driven state is what the next toggle press will invert.
            case 0xB0 when _mapping.TryMapButtonCc(d1, out var button):
                _buttons.HandleFeedback(button, d2 > 0);
                break;

            // Ring value 0-11 for an encoder.
            case 0xB0 when _mapping.TryMapRingValueCc(d1, out var enc):
                lock (_ringGate)
                {
                    _ringValues[enc] = (byte)Math.Min((int)d2, NocturnProtocol.RingSegments);
                    _leds.SetRing(enc, _ringModes[enc], _ringValues[enc]);
                }
                break;

            // Speed dial ring value 0-11.
            case 0xB0 when d1 == _mapping.SpeedDialRingCc:
                _leds.SetSpeedDialRing((byte)Math.Min((int)d2, NocturnProtocol.RingSegments));
                break;

            // Ring mode 0-5 for an encoder. The page table sets a mode per
            // page; a DAW override still wins for as long as that page is
            // current, which is what a codec that knows the item's shape
            // needs in order to correct our default.
            case 0xB0 when _mapping.TryMapRingModeCc(d1, out var modeEnc):
                if (d2 <= (byte)RingMode.SingleDotInverted)
                {
                    lock (_ringGate)
                    {
                        _ringModes[modeEnc] = (RingMode)d2;
                        _leds.SetRing(modeEnc, _ringModes[modeEnc], _ringValues[modeEnc]);
                    }
                }
                break;
        }
    }

    private void OnDisconnected(IMidiEndpointConnectionSource sender, object args) =>
        _log.LogWarning("MIDI endpoint disconnected; waiting for auto-reconnect.");

    private void OnReconnected(IMidiEndpointConnectionSource sender, object args) =>
        _log.LogInformation("MIDI endpoint reconnected.");

    public override void Dispose()
    {
        _listener.InputReceived -= OnInput;
        Teardown();
        base.Dispose();
    }

    private void Teardown()
    {
        if (_connection is not null)
        {
            _connection.MessageReceived -= OnMessage;
            _connection.EndpointDeviceDisconnected -= OnDisconnected;
            _connection.EndpointDeviceReconnected -= OnReconnected;
            _connection = null;
        }

        if (_session is not null)
        {
            // Disposing the session closes every connection it owns — the
            // projected connection exposes no Close/Dispose of its own.
            _session.Dispose();
            _session = null;
        }
    }
}
