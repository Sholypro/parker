using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;

namespace Parker
{
    /// <summary>Win32 calls used by Parker.</summary>
    internal static class Native
    {
        // Hotkeys
        public const int WM_HOTKEY = 0x0312;
        public const uint MOD_ALT = 0x1, MOD_CONTROL = 0x2, MOD_SHIFT = 0x4, MOD_WIN = 0x8, MOD_NOREPEAT = 0x4000;

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        // Window styles
        public const int GWL_EXSTYLE = -20;
        public const int WS_EX_TOOLWINDOW = 0x00000080;
        public const int WS_EX_NOACTIVATE = 0x08000000;
        public const int WS_EX_TRANSPARENT = 0x00000020;
        public const int WS_EX_LAYERED = 0x00080000;
        public const int WS_EX_TOPMOST = 0x00000008;

        // Display affinity: hide our own windows from every capture API (Windows 10 2004+)
        public const uint WDA_NONE = 0x0, WDA_EXCLUDEFROMCAPTURE = 0x11;

        [DllImport("user32.dll")]
        public static extern bool SetWindowDisplayAffinity(IntPtr hWnd, uint dwAffinity);

        public static void ExcludeFromCapture(IntPtr hwnd)
        {
            try { SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE); } catch { }
        }

        // Window enumeration
        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool IsIconic(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetWindowTextLength(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

        [DllImport("user32.dll")]
        public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll")]
        public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT
        {
            public int Left, Top, Right, Bottom;
            public Rectangle ToRectangle() { return Rectangle.FromLTRB(Left, Top, Right, Bottom); }
        }

        // DWM: real window bounds (without the invisible resize border) and "cloaked" state
        public const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;
        public const int DWMWA_CLOAKED = 14;

        [DllImport("dwmapi.dll")]
        public static extern int DwmGetWindowAttribute(IntPtr hwnd, int dwAttribute, out RECT pvAttribute, int cbAttribute);

        [DllImport("dwmapi.dll")]
        public static extern int DwmGetWindowAttribute(IntPtr hwnd, int dwAttribute, out int pvAttribute, int cbAttribute);

        public static Rectangle WindowBounds(IntPtr hwnd)
        {
            RECT r;
            if (DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, out r, Marshal.SizeOf(typeof(RECT))) == 0)
                return r.ToRectangle();
            if (GetWindowRect(hwnd, out r)) return r.ToRectangle();
            return Rectangle.Empty;
        }

        public static bool IsCloaked(IntPtr hwnd)
        {
            int cloaked;
            return DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, out cloaked, sizeof(int)) == 0 && cloaked != 0;
        }

        // Input (auto-scroll)
        [StructLayout(LayoutKind.Sequential)]
        public struct INPUT
        {
            public uint type;
            // MOUSEINPUT is the largest member of the native union: 40 bytes total on 64-bit, 28 on 32-bit
            public MOUSEINPUT mi;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct MOUSEINPUT
        {
            public int dx, dy;
            public int mouseData;
            public uint dwFlags, time;
            public IntPtr dwExtraInfo;
        }

        public const uint INPUT_MOUSE = 0;
        public const uint MOUSEEVENTF_WHEEL = 0x0800;

        [DllImport("user32.dll", SetLastError = true)]
        public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

        [DllImport("user32.dll")]
        public static extern bool SetCursorPos(int x, int y);

        public static void ScrollWheel(int delta)
        {
            var input = new INPUT();
            input.type = INPUT_MOUSE;
            input.mi.dwFlags = MOUSEEVENTF_WHEEL;
            input.mi.mouseData = delta;
            SendInput(1, new[] { input }, Marshal.SizeOf(typeof(INPUT)));
        }

        // DPI of a monitor (Windows 8.1+)
        [DllImport("user32.dll")]
        public static extern IntPtr MonitorFromRect(ref RECT lprc, uint dwFlags);

        [DllImport("shcore.dll")]
        public static extern int GetDpiForMonitor(IntPtr hmonitor, int dpiType, out uint dpiX, out uint dpiY);

        // Keyboard state (Esc during scroll capture while another app is focused)
        [DllImport("user32.dll")]
        public static extern short GetAsyncKeyState(int vKey);
    }

    /// <summary>Scale factor (1.0 = 96 dpi) of the monitor showing a rectangle.</summary>
    internal static class Dpi
    {
        public static float ForRect(Rectangle r)
        {
            try
            {
                var rect = new Native.RECT { Left = r.Left, Top = r.Top, Right = r.Right, Bottom = r.Bottom };
                var mon = Native.MonitorFromRect(ref rect, 2 /* MONITOR_DEFAULTTONEAREST */);
                uint x, y;
                if (Native.GetDpiForMonitor(mon, 0, out x, out y) == 0 && x > 0) return x / 96f;
            }
            catch { }
            return 1f;
        }

        public static float ForPoint(Point p) { return ForRect(new Rectangle(p, new Size(1, 1))); }
    }

    /// <summary>Moves a file to the Recycle Bin (undoable, unlike File.Delete).</summary>
    internal static class RecycleBin
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct SHFILEOPSTRUCT
        {
            public IntPtr hwnd;
            public uint wFunc;
            public string pFrom;
            public string pTo;
            public ushort fFlags;
            public bool fAnyOperationsAborted;
            public IntPtr hNameMappings;
            public string lpszProgressTitle;
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        static extern int SHFileOperation(ref SHFILEOPSTRUCT op);

        const uint FO_DELETE = 3;
        const ushort FOF_ALLOWUNDO = 0x40, FOF_NOCONFIRMATION = 0x10, FOF_SILENT = 0x4, FOF_NOERRORUI = 0x400;

        public static bool Send(string path)
        {
            var op = new SHFILEOPSTRUCT
            {
                wFunc = FO_DELETE,
                pFrom = path + "\0\0",
                fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI,
            };
            return SHFileOperation(ref op) == 0;
        }
    }
}
