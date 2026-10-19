using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Nuts.Driver.Config;
using Nuts.Driver.Device;
using Nuts.Driver.Led;
using Nuts.Driver.Probe;
using Nuts.Driver.Services;

// nuts - Novation Nocturn driver
//
//   nuts-driver            run the driver (USB listener + LED flusher)
//   nuts-driver --probe    Milestone-1 hardware probe (button map, LED colors,
//                          ring modes; see docs/protocol.md)

var builder = Host.CreateApplicationBuilder(new HostApplicationBuilderSettings
{
    Args = args,
    // Resolve appsettings.json next to the executable so the driver works
    // regardless of the working directory it is launched from.
    ContentRootPath = AppContext.BaseDirectory,
});
builder.Services.AddSingleton(DriverOptions.Load(builder.Configuration));
builder.Services.AddSingleton(provider => provider.GetRequiredService<DriverOptions>().Usb);
builder.Services.AddSingleton<NocturnDevice>();
builder.Services.AddSingleton<ILedManager, LedManager>();

if (args.Contains("--probe") || args.Contains("--probe-input"))
{
    builder.Services.AddSingleton<ProbeTool>();
    using var probeHost = builder.Build();
    var log = probeHost.Services.GetRequiredService<ILoggerFactory>().CreateLogger("probe");
    log.LogInformation("Running in hardware probe mode.");
    using var cts = new CancellationTokenSource();
    Console.CancelKeyPress += (_, e) => { e.Cancel = true; cts.Cancel(); };
    await probeHost.Services.GetRequiredService<ProbeTool>().Run(
        cts.Token, inputsOnly: args.Contains("--probe-input"));
    return;
}

builder.Services.AddSingleton<NocturnListenerService>();
builder.Services.AddHostedService(sp => sp.GetRequiredService<NocturnListenerService>());
builder.Services.AddHostedService<LedFlushService>();
builder.Services.AddSingleton<Nuts.Driver.Midi.MidiBridgeService>();
builder.Services.AddHostedService(sp => sp.GetRequiredService<Nuts.Driver.Midi.MidiBridgeService>());

using var host = builder.Build();

var startupLog = host.Services.GetRequiredService<ILoggerFactory>().CreateLogger("startup");
startupLog.LogInformation(
    "nuts driver starting (VID 0x{Vid:X4} / PID 0x{Pid:X4}, flush {Flush}ms)",
    host.Services.GetRequiredService<DriverOptions>().Usb.VendorId,
    host.Services.GetRequiredService<DriverOptions>().Usb.ProductId,
    host.Services.GetRequiredService<DriverOptions>().Led.FlushIntervalMs);

await host.RunAsync();
