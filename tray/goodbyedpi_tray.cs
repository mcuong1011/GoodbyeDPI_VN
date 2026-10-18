// System tray launcher for GoodbyeDPI. Runs goodbyedpi.exe without a console
// window and puts an icon in the notification area to stop/start it and view
// its output. Build with tray\build.cmd.
//
// Usage: goodbyedpi_tray.exe [goodbyedpi arguments]
// Without arguments it uses the same Steam settings as 3_steam_vn_dnsfix.cmd.

using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("GoodbyeDPI tray")]
[assembly: AssemblyProduct("GoodbyeDPI tray")]

static class Program
{
    const string DefaultArgs = "-3 --dns-addr 8.8.8.8 --dns-port 53 --dnsv6-addr 2001:4860:4860::8888 --dnsv6-port 53";

    [STAThread]
    static void Main()
    {
        bool isFirst;
        using (new Mutex(true, "GoodbyeDPI-Tray", out isFirst))
        {
            if (!isFirst)
            {
                MessageBox.Show("GoodbyeDPI is already running in the system tray.\n\n" +
                    "Right-click its icon and choose Exit before starting it again.",
                    "GoodbyeDPI", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            string exe = Path.Combine(AppDomain.CurrentDomain.BaseDirectory,
                Environment.Is64BitOperatingSystem ? "x86_64" : "x86", "goodbyedpi.exe");
            if (!File.Exists(exe))
            {
                MessageBox.Show("Can't find " + exe + "\n\n" +
                    "Keep goodbyedpi_tray.exe in the GoodbyeDPI folder, next to the x86 and x86_64 folders.",
                    "GoodbyeDPI", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            using (var app = new TrayApp(exe, GetGoodbyeDpiArgs()))
            {
                if (!app.Start())
                    return;
                app.ShowStartedTip();
                Application.Run(app);
            }
        }
    }

    // Everything after our own exe path, passed through to goodbyedpi.exe unchanged.
    static string GetGoodbyeDpiArgs()
    {
        string cmd = Environment.CommandLine.TrimStart();
        int end = cmd.StartsWith("\"") ? cmd.IndexOf('"', 1) + 1 : cmd.IndexOf(' ');
        string rest = end <= 0 ? "" : cmd.Substring(end).Trim();
        return rest.Length > 0 ? rest : DefaultArgs;
    }
}

class TrayApp : ApplicationContext
{
    readonly string exe, args;
    readonly NotifyIcon tray = new NotifyIcon();
    readonly Icon runningIcon, stoppedIcon;
    readonly LogWindow log;
    readonly ToolStripMenuItem statusItem, toggleItem;
    readonly IntPtr job = Job.CreateKillOnClose();
    Process proc;
    bool stopping;
    volatile bool exiting;

    public TrayApp(string exe, string args)
    {
        this.exe = exe;
        this.args = args;

        Icon large, small;
        LoadIcons(Application.ExecutablePath, out large, out small);
        runningIcon = small;
        stoppedIcon = Grayed(small);

        log = new LogWindow(large);
        IntPtr unused = log.Handle; // background threads marshal output to the UI thread through this handle

        statusItem = new ToolStripMenuItem { Enabled = false };
        toggleItem = new ToolStripMenuItem("", null, (s, e) => { if (proc != null) Stop(); else Start(); });
        var menu = new ContextMenuStrip();
        menu.Items.Add(statusItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(toggleItem);
        menu.Items.Add("Show log", null, (s, e) => log.ShowAndActivate());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Exit", null, (s, e) => Exit());

        tray.ContextMenuStrip = menu;
        tray.DoubleClick += (s, e) => log.ShowAndActivate();
        tray.BalloonTipClicked += (s, e) => log.ShowAndActivate();
        UpdateState();
    }

    public bool Start()
    {
        Process[] running = Process.GetProcessesByName("goodbyedpi");
        if (running.Length > 0)
        {
            // Two copies would both rewrite the same packets.
            MessageBox.Show(running[0].SessionId == 0
                ? "The GoodbyeDPI service is already running in the background, so there is nothing to start.\n\n" +
                  "To use the tray icon instead, run service_remove.cmd as administrator, then try again."
                : "GoodbyeDPI is already running (process " + running[0].Id + "), probably in a console window.\n\n" +
                  "Close it, then try again.",
                "GoodbyeDPI", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return false;
        }

        var p = new Process();
        p.StartInfo = new ProcessStartInfo(exe, args)
        {
            WorkingDirectory = Path.GetDirectoryName(exe),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        p.EnableRaisingEvents = true;
        p.OutputDataReceived += OnOutput;
        p.ErrorDataReceived += OnOutput;
        p.Exited += OnExited;
        try
        {
            p.Start();
        }
        catch (Win32Exception ex)
        {
            MessageBox.Show("Couldn't start " + exe + ":\n\n" + ex.Message,
                "GoodbyeDPI", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return false;
        }
        Job.Assign(job, p);
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();

        proc = p;
        stopping = false;
        log.Append(Stamp() + "Started goodbyedpi.exe " + args + " (PID " + p.Id + ")");
        // goodbyedpi.exe never flushes stdout, so when it's a pipe its banner only
        // arrives once it exits. Startup errors still show up here because of that.
        UpdateState();
        tray.Visible = true;
        return true;
    }

    public void ShowStartedTip()
    {
        tray.ShowBalloonTip(5000, "GoodbyeDPI is running",
            "It runs in the background now. Right-click the tray icon to stop it or see its log.",
            ToolTipIcon.Info);
    }

    void Stop()
    {
        stopping = true;
        try { proc.Kill(); }
        catch (InvalidOperationException) { } // already exited
        catch (Win32Exception) { }            // already exiting
    }

    void Exit()
    {
        exiting = true;
        if (proc != null)
        {
            try { proc.Kill(); proc.WaitForExit(3000); }
            catch (InvalidOperationException) { }
            catch (Win32Exception) { }
        }
        tray.Visible = false;
        ExitThread();
    }

    void OnOutput(object sender, DataReceivedEventArgs e)
    {
        if (e.Data != null)
            Ui(() => log.Append(e.Data));
    }

    // Runs on a thread pool thread.
    void OnExited(object sender, EventArgs e)
    {
        var p = (Process)sender;
        p.WaitForExit(); // drains the redirected output, so it lands in the log before the exit line
        Ui(() => Exited(p));
    }

    void Exited(Process p)
    {
        if (p != proc)
            return;
        proc = null;
        int code = p.ExitCode;
        p.Dispose();
        UpdateState();

        if (stopping)
        {
            log.Append(Stamp() + "Stopped.");
            return;
        }
        log.Append(Stamp() + "goodbyedpi.exe exited with code " + code + ".");
        tray.ShowBalloonTip(10000, "GoodbyeDPI stopped",
            "goodbyedpi.exe exited unexpectedly (code " + code + "). Click here to see its log.",
            ToolTipIcon.Warning);
    }

    void UpdateState()
    {
        bool running = proc != null;
        tray.Icon = running ? runningIcon : stoppedIcon;
        tray.Text = running ? "GoodbyeDPI: running" : "GoodbyeDPI: stopped";
        statusItem.Text = running ? "GoodbyeDPI is running" : "GoodbyeDPI is stopped";
        toggleItem.Text = running ? "Stop" : "Start";
    }

    void Ui(Action action)
    {
        if (exiting)
            return;
        try { log.BeginInvoke(action); }
        catch (InvalidOperationException) { } // window already gone during exit
    }

    static string Stamp()
    {
        return DateTime.Now.ToString("[HH:mm:ss] ");
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int ExtractIconEx(string file, int index, IntPtr[] large, IntPtr[] small, int count);

    static void LoadIcons(string file, out Icon large, out Icon small)
    {
        var l = new IntPtr[1];
        var s = new IntPtr[1];
        ExtractIconEx(file, 0, l, s, 1);
        large = l[0] != IntPtr.Zero ? Icon.FromHandle(l[0]) : SystemIcons.Application;
        small = s[0] != IntPtr.Zero ? Icon.FromHandle(s[0]) : SystemIcons.Application;
    }

    static Icon Grayed(Icon icon)
    {
        using (Bitmap bmp = icon.ToBitmap())
        using (var gray = (Bitmap)ToolStripRenderer.CreateDisabledImage(bmp))
            return Icon.FromHandle(gray.GetHicon());
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            tray.Dispose();
            log.Dispose();
        }
        base.Dispose(disposing);
    }
}

class LogWindow : Form
{
    readonly TextBox text = new TextBox();

    public LogWindow(Icon icon)
    {
        SuspendLayout();
        AutoScaleDimensions = new SizeF(96F, 96F);
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(720, 420);
        Text = "GoodbyeDPI log";
        Icon = icon;
        StartPosition = FormStartPosition.CenterScreen;

        text.Dock = DockStyle.Fill;
        text.Multiline = true;
        text.ReadOnly = true;
        text.BackColor = SystemColors.Window;
        text.ScrollBars = ScrollBars.Both;
        text.WordWrap = false;
        text.Font = new Font("Consolas", 9.75F);
        Controls.Add(text);
        ResumeLayout(false);
    }

    public void Append(string line)
    {
        text.AppendText(line + Environment.NewLine);
    }

    public void ShowAndActivate()
    {
        Show();
        if (WindowState == FormWindowState.Minimized)
            WindowState = FormWindowState.Normal;
        Activate();
    }

    // Closing the log only hides it. Exit from the tray menu quits.
    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            Hide();
        }
        base.OnFormClosing(e);
    }
}

// Ties goodbyedpi.exe's lifetime to the tray app: if the tray app is killed
// (Task Manager, crash), Windows closes the job and ends goodbyedpi.exe with it,
// so it never keeps running with no icon to stop it.
static class Job
{
    const int JobObjectExtendedLimitInformation = 9;
    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

    public static IntPtr CreateKillOnClose()
    {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(job, JobObjectExtendedLimitInformation, ref info,
            Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)));
        return job;
    }

    // Best effort: if this fails, goodbyedpi.exe just isn't tied to the tray app.
    public static void Assign(IntPtr job, Process p)
    {
        AssignProcessToJobObject(job, p.Handle);
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CreateJobObject(IntPtr attributes, string name);

    [DllImport("kernel32.dll")]
    static extern bool SetInformationJobObject(IntPtr job, int infoClass,
        ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, int length);

    [DllImport("kernel32.dll")]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }
}
