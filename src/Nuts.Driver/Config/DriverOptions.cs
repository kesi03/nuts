using Microsoft.Extensions.Configuration;
using Nuts.Driver.Midi;

namespace Nuts.Driver.Config;

public sealed class DriverOptions
{
    public UsbOptions Usb { get; set; } = new();
    public LedOptions Led { get; set; } = new();
    public MidiOptions Midi { get; set; } = new();

    public static DriverOptions Load(IConfiguration configuration)
    {
        var options = new DriverOptions();
        var usb = configuration.GetSection("Usb");

        // The default binder can't parse "0x1235" hex strings into ints,
        // so the numeric USB fields are parsed manually.
        options.Usb.VendorId = ParseInt(usb["VendorId"], "Usb:VendorId");
        options.Usb.ProductId = ParseInt(usb["ProductId"], "Usb:ProductId");
        options.Usb.OutEndpoint = ParseInt(usb["OutEndpoint"], "Usb:OutEndpoint");
        options.Usb.InEndpoint = ParseInt(usb["InEndpoint"], "Usb:InEndpoint");
        options.Usb.ReadTimeoutMs = ParseInt(usb["ReadTimeoutMs"], "Usb:ReadTimeoutMs");
        options.Usb.WriteTimeoutMs = ParseInt(usb["WriteTimeoutMs"], "Usb:WriteTimeoutMs");
        options.Usb.ReconnectIntervalMs = ParseInt(usb["ReconnectIntervalMs"], "Usb:ReconnectIntervalMs");
        options.Usb.SendFactoryInit = ParseBool(usb["SendFactoryInit"], "Usb:SendFactoryInit", true);

        configuration.GetSection("Led").Bind(options.Led);
        configuration.GetSection("Midi").Bind(options.Midi);

        options.Validate();
        return options;
    }

    private static int ParseInt(string? raw, string key)
    {
        if (string.IsNullOrWhiteSpace(raw))
            throw new InvalidOperationException($"Config key '{key}' is missing.");
        raw = raw.Trim();
        try
        {
            return raw.StartsWith("0x", StringComparison.OrdinalIgnoreCase)
                ? Convert.ToInt32(raw, 16)
                : int.Parse(raw);
        }
        catch (Exception ex) when (ex is FormatException or OverflowException)
        {
            throw new InvalidOperationException($"Config key '{key}' has invalid numeric value '{raw}'.");
        }
    }

    private static bool ParseBool(string? raw, string key, bool fallback)
    {
        if (string.IsNullOrWhiteSpace(raw))
            return fallback;
        if (!bool.TryParse(raw, out var value))
            throw new InvalidOperationException($"Config key '{key}' has invalid boolean value '{raw}'.");
        return value;
    }

    public void Validate()
    {
        if (Usb.VendorId <= 0 || Usb.VendorId > 0xFFFF)
            throw new InvalidOperationException("Usb:VendorId must be a 16-bit value (e.g. \"0x1235\").");
        if (Usb.ProductId <= 0 || Usb.ProductId > 0xFFFF)
            throw new InvalidOperationException("Usb:ProductId must be a 16-bit value (e.g. \"0x000A\").");
        if (Usb.OutEndpoint == 0)
            throw new InvalidOperationException("Usb:OutEndpoint must be set (Nocturn uses 0x02).");
        if (Usb.InEndpoint == 0)
            throw new InvalidOperationException("Usb:InEndpoint must be set (Nocturn uses 0x81).");
        if (Led.FlushIntervalMs < 1)
            throw new InvalidOperationException("Led:FlushIntervalMs must be >= 1.");
        if (Led.MaxPairsPerTransfer is < 1 or > 4)
            throw new InvalidOperationException("Led:MaxPairsPerTransfer must be 1..4 (8-byte USB transfer).");
    }
}

public sealed class UsbOptions
{
    /// <summary>Novation VID. Hex strings ("0x1235") and decimals both parse.</summary>
    public int VendorId { get; set; }

    /// <summary>Nocturn PID.</summary>
    public int ProductId { get; set; }

    /// <summary>Interrupt OUT endpoint address (2 = 0x02).</summary>
    public int OutEndpoint { get; set; }

    /// <summary>Interrupt IN endpoint address (0x81).</summary>
    public int InEndpoint { get; set; }

    public int ReadTimeoutMs { get; set; } = 500;
    public int WriteTimeoutMs { get; set; } = 500;
    public int ReconnectIntervalMs { get; set; } = 2000;

    /// <summary>
    /// Send the "B0 00 00" reset plus the undocumented config pairs
    /// (see docs/protocol.md) after opening the device.
    /// </summary>
    public bool SendFactoryInit { get; set; } = true;
}

public sealed class LedOptions
{
    /// <summary>How often dirty LED state is flushed to the device.</summary>
    public int FlushIntervalMs { get; set; } = 10;

    /// <summary>Max [ctrl,val] pairs per 8-byte interrupt transfer.</summary>
    public int MaxPairsPerTransfer { get; set; } = 4;
}

public sealed class MidiOptions
{
    /// <summary>
    /// Bridge surface I/O to a Windows MIDI Services basic-loopback
    /// endpoint so a DAW (Reason, etc.) can control the LEDs and receive
    /// the controls. See docs/midi-mapping.md.
    /// </summary>
    public bool Enabled { get; set; }

    /// <summary>Name of the WMS session owned by the driver.</summary>
    public string SessionName { get; set; } = "nuts driver";

    /// <summary>
    /// Name of the loopback endpoint the DAW and the driver share. Reason 10
    /// enumerates it as a WinMM MIDI in/out port (verified 2026-10-19).
    /// </summary>
    public string EndpointName { get; set; } = "Nocturn";

    /// <summary>
    /// CC numbers used for the surface mapping. Must match the Reason
    /// codec's tables (remote/mapping/nocturn-controls.json + Nocturn.lua).
    /// </summary>
    public MidiMappingOptions Mapping { get; set; } = new();

    /// <summary>
    /// Create the loopback endpoint at startup when it is missing. Transient
    /// loopbacks do not survive a MIDI service restart, so this makes the
    /// driver self-healing.
    /// </summary>
    public bool CreateLoopbackIfMissing { get; set; } = true;
}
