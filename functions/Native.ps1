Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace RClauncher {
    public static class MouseHook {
        private delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
        [StructLayout(LayoutKind.Sequential)]
        private struct MouseInfo {
            public Point point;
            public uint mouseData;
            public uint flags;
            public uint time;
            public IntPtr extraInfo;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct Point { public int x; public int y; }
        [DllImport("user32.dll", SetLastError=true)]
        private static extern IntPtr SetWindowsHookEx(int id, HookProc callback, IntPtr module, uint threadId);
        [DllImport("user32.dll", SetLastError=true)]
        private static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32.dll")]
        private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll", CharSet=CharSet.Auto)]
        private static extern IntPtr GetModuleHandle(string name);
        [DllImport("user32.dll")]
        private static extern IntPtr WindowFromPoint(Point point);
        [DllImport("user32.dll")]
        private static extern IntPtr GetAncestor(IntPtr hwnd, uint flag);
        [DllImport("user32.dll", CharSet=CharSet.Unicode)]
        private static extern int GetClassName(IntPtr hwnd, System.Text.StringBuilder text, int max);
        [DllImport("user32.dll", SetLastError=true)]
        private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern IntPtr OpenProcess(uint access, bool inherit, uint processId);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern IntPtr VirtualAllocEx(IntPtr process, IntPtr address, UIntPtr size, uint allocationType, uint protect);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool VirtualFreeEx(IntPtr process, IntPtr address, UIntPtr size, uint freeType);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool WriteProcessMemory(IntPtr process, IntPtr address, ref HitTestInfo buffer, UIntPtr size, out UIntPtr written);
        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);
        [DllImport("user32.dll", SetLastError=true)]
        private static extern IntPtr ScreenToClient(IntPtr hwnd, ref Point point);
        [DllImport("user32.dll", SetLastError=true)]
        private static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out UIntPtr result);
        [StructLayout(LayoutKind.Sequential)]
        private struct HitTestInfo { public Point point; public uint flags; public int item; public int subItem; public int group; }

        private static HookProc proc = Callback;
        private static IntPtr hook;
        public static Func<uint,int,int,uint,bool> Handler;
        public static int DoubleClickTime { get { return (int)GetDoubleClickTimeNative(); } }
        [DllImport("user32.dll", EntryPoint="GetDoubleClickTime")]
        private static extern uint GetDoubleClickTimeNative();
        [DllImport("user32.dll", CharSet=CharSet.Unicode)]
        private static extern uint RegisterClipboardFormat(string format);
        [DllImport("user32.dll")]
        private static extern bool IsClipboardFormatAvailable(uint format);
        private static uint excludeClipboardFormat;
        public static void RegisterClipboardExclusionFormat() {
            excludeClipboardFormat = RegisterClipboardFormat("ExcludeClipboardContentFromMonitorProcessing");
        }
        public static bool IsClipboardExcluded() {
            return excludeClipboardFormat != 0 && IsClipboardFormatAvailable(excludeClipboardFormat);
        }

        public static void Install() {
            if (hook != IntPtr.Zero) return;
            using (Process p = Process.GetCurrentProcess())
            using (ProcessModule m = p.MainModule) {
                hook = SetWindowsHookEx(14, proc, GetModuleHandle(m.ModuleName), 0);
            }
            if (hook == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        public static void Uninstall() {
            if (hook != IntPtr.Zero) { UnhookWindowsHookEx(hook); hook = IntPtr.Zero; }
            Handler = null;
        }
        public static bool IsDesktop(int x, int y) {
            Point pt = new Point { x=x, y=y };
            IntPtr first = WindowFromPoint(pt), current = first;
            for (int i=0; i<8 && current != IntPtr.Zero; i++) {
                var name = new System.Text.StringBuilder(80);
                GetClassName(current, name, name.Capacity);
                string cls = name.ToString();
                if (cls == "Progman" || cls == "WorkerW") return first != IntPtr.Zero;
                current = GetAncestor(current, 1);
            }
            return false;
        }
        public static bool IsEmptyDesktopSpot(int x, int y) {
            Point pt = new Point { x=x, y=y };
            IntPtr first = WindowFromPoint(pt);
            if (first == IntPtr.Zero) return false;
            var name = new System.Text.StringBuilder(80);
            GetClassName(first, name, name.Capacity);
            if (name.ToString() == "SysListView32") return IsEmptyListView(first, pt);
            return IsDesktop(x, y);
        }
        private static bool IsEmptyListView(IntPtr list, Point screenPoint) {
            Point client = screenPoint;
            if (ScreenToClient(list, ref client) == IntPtr.Zero) return false;
            uint pid;
            GetWindowThreadProcessId(list, out pid);
            IntPtr process = OpenProcess(0x0008 | 0x0020, false, pid);
            if (process == IntPtr.Zero) return false;
            IntPtr remote = IntPtr.Zero;
            try {
                HitTestInfo info = new HitTestInfo { point=client, item=-1 };
                UIntPtr size = new UIntPtr((uint)Marshal.SizeOf(typeof(HitTestInfo))), written;
                remote = VirtualAllocEx(process, IntPtr.Zero, size, 0x1000 | 0x2000, 0x04);
                if (remote == IntPtr.Zero || !WriteProcessMemory(process, remote, ref info, size, out written)) return false;
                UIntPtr result;
                IntPtr sent = SendMessageTimeout(list, 0x1012, IntPtr.Zero, remote, 0x0002, 300, out result);
                return sent != IntPtr.Zero && unchecked((int)result.ToUInt64()) == -1;
            } finally {
                if (remote != IntPtr.Zero) VirtualFreeEx(process, remote, UIntPtr.Zero, 0x8000);
                CloseHandle(process);
            }
        }
        private static IntPtr Callback(int code, IntPtr wParam, IntPtr lParam) {
            if (code >= 0 && Handler != null) {
                try {
                    MouseInfo info = (MouseInfo)Marshal.PtrToStructure(lParam, typeof(MouseInfo));
                    if ((info.flags & 1) == 0 && Handler((uint)wParam.ToInt32(), info.point.x, info.point.y, info.time))
                        return new IntPtr(1);
                } catch { }
            }
            return CallNextHookEx(hook, code, wParam, lParam);
        }
    }
    public static class FolderIcon {
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Auto)]
        private struct ShellFileInfo {
            public IntPtr icon;
            public int iconIndex;
            public uint attributes;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)]
            public string displayName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst=80)]
            public string typeName;
        }
        [DllImport("shell32.dll", CharSet=CharSet.Auto)]
        private static extern IntPtr SHGetFileInfo(string path, uint attributes, out ShellFileInfo info, uint size, uint flags);
        [DllImport("user32.dll", SetLastError=true)]
        private static extern bool DestroyIcon(IntPtr icon);

        public static IntPtr Get(string path) {
            ShellFileInfo info;
            SHGetFileInfo(path, 0, out info, (uint)Marshal.SizeOf(typeof(ShellFileInfo)), 0x100 | 0x1);
            return info.icon;
        }
        public static void Release(IntPtr icon) { if (icon != IntPtr.Zero) DestroyIcon(icon); }
    }
}
'@
