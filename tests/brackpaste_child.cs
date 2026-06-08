// Bracketed-paste reader: enables bracketed paste (ESC[?2004h) like Copilot CLI /
// Claude Code do, then logs every raw input byte. Used to prove PR #357 delivers a
// paste that starts with a newline INSIDE the bracket (ESC[200~ ... 0A ... ESC[201~)
// with no premature standalone Enter before it.
using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;

class BrackPaste {
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetConsoleMode(IntPtr h, out uint mode);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetConsoleMode(IntPtr h, uint mode);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReadFile(IntPtr h, byte[] buf, uint n, out uint read, IntPtr ov);

    const int STD_INPUT_HANDLE = -10, STD_OUTPUT_HANDLE = -11;
    const uint ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200;
    const uint ENABLE_PROCESSED_INPUT = 0x0001, ENABLE_LINE_INPUT = 0x0002, ENABLE_ECHO_INPUT = 0x0004;
    const uint ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004;

    static int Main() {
        string log = Path.Combine(Environment.GetEnvironmentVariable("TEMP"), "psmux_brackpaste.txt");
        File.WriteAllText(log, "BRACKPASTE START\n");
        IntPtr hin = GetStdHandle(STD_INPUT_HANDLE);
        IntPtr hout = GetStdHandle(STD_OUTPUT_HANDLE);
        uint omode; GetConsoleMode(hout, out omode);
        SetConsoleMode(hout, omode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
        uint mode; GetConsoleMode(hin, out mode);
        SetConsoleMode(hin, (mode & ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT)) | ENABLE_VIRTUAL_TERMINAL_INPUT);
        // Enable bracketed paste (like a real CLI TUI)
        var on = Encoding.ASCII.GetBytes("\x1b[?2004h");
        using (var so = Console.OpenStandardOutput()) { so.Write(on, 0, on.Length); so.Flush(); }
        File.AppendAllText(log, "sent ESC[?2004h (bracketed paste ON)\n");
        byte[] buf = new byte[512];
        while (true) {
            uint read;
            if (!ReadFile(hin, buf, (uint)buf.Length, out read, IntPtr.Zero)) { System.Threading.Thread.Sleep(20); continue; }
            if (read == 0) { System.Threading.Thread.Sleep(10); continue; }
            var sb = new StringBuilder();
            for (uint i = 0; i < read; i++) sb.AppendFormat("0x{0:X2} ", buf[i]);
            File.AppendAllText(log, sb.ToString().TrimEnd() + "\n");
            for (uint i = 0; i < read; i++) if (buf[i] == 0x1A) { File.AppendAllText(log, "BRACKPASTE END\n"); return 0; }
        }
    }
}
