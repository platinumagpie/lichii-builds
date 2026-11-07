using System;
using System.Runtime.InteropServices;

namespace LichiiTray
{
    public static class Native
    {
        [DllImport("shell32.dll")]
        private static extern int SHQueryUserNotificationState(out int state);

        [DllImport("shcore.dll")]
        private static extern int SetProcessDpiAwareness(int value);

        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

        // Render at the real screen resolution instead of letting Windows blow up a blurry 96-dpi bitmap.
        public static void MakeDpiAware()
        {
            try { if (SetProcessDpiAwareness(1) == 0) return; } catch { }   // PROCESS_SYSTEM_DPI_AWARE
            try { SetProcessDPIAware(); } catch { }
        }

        // 5 = QUNS_ACCEPTS_NOTIFICATIONS (nothing fullscreen); 2/3/4/7 = fullscreen app, D3D game, presentation, store app
        public static int NotificationState()
        {
            int s = 5;
            try { SHQueryUserNotificationState(out s); } catch { s = 5; }
            return s;
        }

        // The modern Explorer-style "Select folder" dialog. Returns null if cancelled.
        public static string PickFolder(IntPtr owner, string title, string startFolder)
        {
            IFileOpenDialog d = (IFileOpenDialog)new FileOpenDialogRCW();
            try
            {
                uint opts;
                d.GetOptions(out opts);
                d.SetOptions(opts | 0x20 | 0x40);           // FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM
                if (!string.IsNullOrEmpty(title)) d.SetTitle(title);
                string start = startFolder;
                while (!string.IsNullOrEmpty(start) && !System.IO.Directory.Exists(start))
                    start = System.IO.Path.GetDirectoryName(start);
                if (!string.IsNullOrEmpty(start))
                {
                    IShellItem si;
                    SHCreateItemFromParsingName(start, IntPtr.Zero, typeof(IShellItem).GUID, out si);
                    d.SetFolder(si);
                }
                if (d.Show(owner) != 0) return null;
                IShellItem result;
                d.GetResult(out result);
                IntPtr p;
                result.GetDisplayName(0x80058000, out p);   // SIGDN_FILESYSPATH
                string path = Marshal.PtrToStringUni(p);
                Marshal.FreeCoTaskMem(p);
                return path;
            }
            finally { Marshal.ReleaseComObject(d); }
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern void SHCreateItemFromParsingName(string pszPath, IntPtr pbc,
            [MarshalAs(UnmanagedType.LPStruct)] Guid riid, out IShellItem ppv);

        [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")]
        private class FileOpenDialogRCW { }

        [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IFileOpenDialog
        {
            [PreserveSig] int Show(IntPtr parent);
            void SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
            void SetFileTypeIndex(uint iFileType);
            void GetFileTypeIndex(out uint piFileType);
            void Advise(IntPtr pfde, out uint pdwCookie);
            void Unadvise(uint dwCookie);
            void SetOptions(uint fos);
            void GetOptions(out uint pfos);
            void SetDefaultFolder(IShellItem psi);
            void SetFolder(IShellItem psi);
            void GetFolder(out IShellItem ppsi);
            void GetCurrentSelection(out IShellItem ppsi);
            void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
            void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string pszName);
            void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
            void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
            void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
            void GetResult(out IShellItem ppsi);
            void AddPlace(IShellItem psi, int alignment);
            void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string pszDefaultExtension);
            void Close(int hr);
            void SetClientGuid(ref Guid guid);
            void ClearClientData();
            void SetFilter(IntPtr pFilter);
            void GetResults(out IntPtr ppenum);
            void GetSelectedItems(out IntPtr ppsai);
        }

        [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IShellItem
        {
            void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
            void GetParent(out IShellItem ppsi);
            void GetDisplayName(uint sigdnName, out IntPtr ppszName);
            void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
            void Compare(IShellItem psi, uint hint, out int piOrder);
        }

        // Windows 11 rounded corners + dark frame for a popup (ignored on Windows 10)
        public static void Win11Popup(IntPtr hwnd)
        {
            try { int round = 2; DwmSetWindowAttribute(hwnd, 33, ref round, 4); } catch { }
            try { int dark = 1; DwmSetWindowAttribute(hwnd, 20, ref dark, 4); } catch { }
            try { int border = 0x00404040; DwmSetWindowAttribute(hwnd, 34, ref border, 4); } catch { }
        }
    }
}
