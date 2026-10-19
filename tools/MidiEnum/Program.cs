using System;
using System.Threading.Tasks;
using Windows.Devices.Enumeration;
using Windows.Devices.Midi;

// Throwaway diagnostic: what does the modern Windows MIDI stack see?
// (Legacy winmm sees nothing on 25H2; the question is whether midisrv's
// KS transport surfaces the Nocturn's nvnusbaudio KS MIDI pin.)
internal static class Program
{
    private const string MidiClassAqs =
        "System.Devices.InterfaceClassGuid:{504BE32C-CCF6-4D2C-B73F-6F8B3747E22B}";

    private static async Task Main()
    {
        Console.WriteLine("MidiInPort type members:");
        foreach (var m in typeof(MidiInPort).GetMethods())
            if (m.IsStatic) Console.WriteLine($"  static {m.Name}");

        var ins = await DeviceInformation.FindAllAsync(MidiInPort.GetDeviceSelector());
        Console.WriteLine($"MidiInPort devices ({ins.Count}):");
        foreach (var d in ins)
            Console.WriteLine($"  IN   {d.Name,-40} {d.Id}");

        var outs = await DeviceInformation.FindAllAsync(MidiOutPort.GetDeviceSelector());
        Console.WriteLine($"MidiOutPort devices ({outs.Count}):");
        foreach (var d in outs)
            Console.WriteLine($"  OUT  {d.Name,-40} {d.Id}");

        // Raw device enumeration on the MIDI device-interface class as a
        // cross-check.
        var midiClass = await DeviceInformation.FindAllAsync(MidiClassAqs);
        Console.WriteLine($"MIDI interface class ({midiClass.Count}):");
        foreach (var d in midiClass)
            Console.WriteLine($"  DEV  {d.Name,-40} {d.Id}");
    }
}
