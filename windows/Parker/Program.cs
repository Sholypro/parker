using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Parker
{
    internal static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            bool created;
            using (var mutex = new Mutex(true, "Parker-SholyDesign-SingleInstance", out created))
            {
                if (!created) return; // already running: the tray icon is there
#if !MONO_CHECK
                Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
#endif
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new TrayApp(args.Contains("--startup")));
                GC.KeepAlive(mutex);
            }
        }
    }

    /// <summary>Notification-area app: menu, hotkeys, capture flows.</summary>
    internal sealed class TrayApp : ApplicationContext
    {
        public static readonly Icon AppIcon = LoadIcon("Parker.ico");
        readonly NotifyIcon tray;
        readonly Hotkeys hotkeys;
        readonly ContextMenuStrip menu;
        bool busy;

        static Icon LoadIcon(string name)
        {
            try
            {
                using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
                    if (s != null) return new Icon(s);
            }
            catch { }
            return SystemIcons.Application;
        }

        static bool LightTaskbar()
        {
            try
            {
                using (var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                    return k != null && Convert.ToInt32(k.GetValue("SystemUsesLightTheme", 0)) == 1;
            }
            catch { return false; }
        }

        public TrayApp(bool fromStartup)
        {
            ThumbnailStack.OnEdit = OpenEditor;
            ThumbnailStack.OnPin = Pin;

            menu = new ContextMenuStrip { ShowImageMargin = false, Font = new Font("Segoe UI", 9.5f) };
            tray = new NotifyIcon
            {
                Icon = LightTaskbar() ? AppIcon : LoadIcon("Tray.ico"),
                Text = "Parker",
                Visible = true,
                ContextMenuStrip = menu,
            };
            tray.MouseUp += (s, e) =>
            {
                if (e.Button == MouseButtons.Left)
                {
                    // Show the same menu on left click
                    var mi = typeof(NotifyIcon).GetMethod("ShowContextMenu", BindingFlags.Instance | BindingFlags.NonPublic);
                    if (mi != null) mi.Invoke(tray, null);
                    else menu.Show(Cursor.Position);
                }
            };

            Application.ApplicationExit += (s, e) => { tray.Visible = false; };

            hotkeys = new Hotkeys();
            var mods = Native.MOD_CONTROL | Native.MOD_SHIFT;
            hotkeys.Register(new Hotkeys.Binding { Name = "Capturer une zone", Modifiers = mods, Key = Keys.D4, Action = CaptureArea });
            hotkeys.Register(new Hotkeys.Binding { Name = "Capturer tout l'écran", Modifiers = mods, Key = Keys.D3, Action = CaptureFullscreen });
            hotkeys.Register(new Hotkeys.Binding { Name = "Capturer une fenêtre", Modifiers = mods, Key = Keys.D5, Action = CaptureWindow });
            hotkeys.Register(new Hotkeys.Binding { Name = "Capture défilante", Modifiers = mods, Key = Keys.D6, Action = CaptureScrolling });
            hotkeys.Register(new Hotkeys.Binding { Name = "Épingler la dernière capture", Modifiers = mods, Key = Keys.D7, Action = PinLast });

            BuildMenu();
            menu.Opening += (s, e) => BuildMenu();

            Startup.Apply(Settings.Current.LaunchAtStartup);

            if (!Settings.Current.FirstRunDone)
            {
                Settings.Current.FirstRunDone = true;
                Settings.Current.Save();
                tray.ShowBalloonTip(6000, "Parker est prêt",
                    "Ctrl+Maj+4 : capturer une zone · Ctrl+Maj+6 : capture défilante. Clique sur l'icône Parker pour le menu.",
                    ToolTipIcon.None);
            }
            if (hotkeys.Failed.Count > 0 && !fromStartup)
            {
                tray.ShowBalloonTip(6000, "Raccourcis déjà utilisés",
                    "Ces raccourcis sont pris par une autre app : " + string.Join(", ", hotkeys.Failed.Select(b => b.Display)) + ". Utilise le menu Parker.",
                    ToolTipIcon.Warning);
            }

            Updater.CheckInBackgroundIfNeeded();
        }

        string ShortcutFor(string name)
        {
            var b = new[] { "Capturer une zone|Ctrl+Maj+4", "Capturer tout l'écran|Ctrl+Maj+3", "Capturer une fenêtre|Ctrl+Maj+5", "Capture défilante|Ctrl+Maj+6", "Épingler la dernière capture|Ctrl+Maj+7" }
                .FirstOrDefault(x => x.StartsWith(name + "|"));
            return b == null ? "" : b.Split('|')[1];
        }

        void BuildMenu()
        {
            menu.Items.Clear();
            Action<string, Action> item = (text, action) =>
            {
                var mi = new ToolStripMenuItem(text, null, (s, e) => action());
                var sc = ShortcutFor(text);
                if (sc.Length > 0) mi.ShortcutKeyDisplayString = sc;
                menu.Items.Add(mi);
            };
            item("Capturer une zone", CaptureArea);
            item("Capturer tout l'écran", CaptureFullscreen);
            item("Capturer une fenêtre", CaptureWindow);
            item("Capture défilante", CaptureScrolling);

            var timed = new ToolStripMenuItem("Capture avec retardateur");
            foreach (var sec in new[] { 3, 5, 10 })
            {
                var d = sec;
                timed.DropDownItems.Add("Écran entier dans " + d + " s", null, (s, e) => Delayed(d, CaptureFullscreen));
            }
            menu.Items.Add(timed);
            menu.Items.Add(new ToolStripSeparator());

            item("Épingler la dernière capture", PinLast);
            var recent = new ToolStripMenuItem("Captures récentes");
            var files = Settings.Current.Recent.Where(File.Exists).Take(10).ToList();
            if (files.Count == 0) recent.DropDownItems.Add(new ToolStripMenuItem("Aucune capture récente") { Enabled = false });
            foreach (var f in files)
            {
                var path = f;
                recent.DropDownItems.Add(Path.GetFileNameWithoutExtension(path), null, (s, e) => OpenEditor(path));
            }
            menu.Items.Add(recent);
            item("Ouvrir le dossier des captures", () =>
            {
                Directory.CreateDirectory(Settings.Current.SaveFolder);
                Process.Start("explorer.exe", "\"" + Settings.Current.SaveFolder + "\"");
            });
            menu.Items.Add(new ToolStripSeparator());
            item("Réglages…", ShowSettings);
            item("Rechercher des mises à jour…", () => Updater.Check(true));
            item("À propos de Parker", () => MessageBox.Show(
                "Parker " + Updater.CurrentText + "\nCapture, annotation et capture défilante.\n\nBasé sur ScreenCap (open source, licence MIT).",
                "À propos de Parker", MessageBoxButtons.OK, MessageBoxIcon.Information));
            item("Quitter Parker", ExitApp);
        }

        // ---------- Capture flows ----------

        void Run(Action action)
        {
            if (busy) return;
            busy = true;
            try { action(); }
            catch (Exception ex) { busy = false; Toast.Show("Erreur : " + ex.Message, 4000); }
        }

        void Done(string path)
        {
            busy = false;
            if (path != null) ThumbnailStack.Show(path);
        }

        void CaptureArea()
        {
            Run(() => Selector.Show(SelectMode.Area, (rect, snapshot) =>
            {
                string path = null;
                if (rect.HasValue)
                    using (var img = ScreenGrab.Crop(snapshot, rect.Value)) path = ImageStore.Finish(img);
                snapshot.Dispose();
                Done(path);
            }));
        }

        void CaptureWindow()
        {
            Run(() => Selector.Show(SelectMode.Window, (rect, snapshot) =>
            {
                string path = null;
                if (rect.HasValue)
                    using (var img = ScreenGrab.Crop(snapshot, rect.Value)) path = ImageStore.Finish(img);
                snapshot.Dispose();
                Done(path);
            }));
        }

        void CaptureFullscreen()
        {
            Run(() =>
            {
                var screen = ScreenGrab.ScreenUnderCursor();
                using (var img = ScreenGrab.Capture(screen.Bounds))
                {
                    var path = ImageStore.Finish(img);
                    Done(path);
                }
            });
        }

        void CaptureScrolling()
        {
            Run(() =>
            {
                var sc = new ScrollCapture(Done);
                sc.Start();
                // The selection may be cancelled: release the lock shortly after
                var t = new System.Windows.Forms.Timer { Interval = 400 };
                t.Tick += (s, e) => { t.Stop(); t.Dispose(); busy = false; };
                t.Start();
            });
        }

        void Delayed(int seconds, Action action)
        {
            var left = seconds;
            Toast.Show("Capture dans " + left + "…", 900);
            var t = new System.Windows.Forms.Timer { Interval = 1000 };
            t.Tick += (s, e) =>
            {
                left--;
                if (left > 0) { Toast.Show("Capture dans " + left + "…", 900); return; }
                t.Stop(); t.Dispose();
                action();
            };
            t.Start();
        }

        void PinLast()
        {
            var last = Settings.Current.Recent.FirstOrDefault(File.Exists);
            if (last != null) Pin(last); else Toast.Show("Aucune capture à épingler");
        }

        void Pin(string path) { new PinForm(path).Show(); }

        void OpenEditor(string path)
        {
            var editor = new EditorForm(path);
            editor.Show();
            editor.Activate();
        }

        void ShowSettings()
        {
            var keys = "Zone : Ctrl+Maj+4 · Écran : Ctrl+Maj+3 · Fenêtre : Ctrl+Maj+5\nDéfilante : Ctrl+Maj+6 · Épingler : Ctrl+Maj+7";
            using (var f = new SettingsForm(keys)) f.ShowDialog();
        }

        void ExitApp()
        {
            ThumbnailStack.CloseAll();
            hotkeys.Dispose();
            tray.Visible = false;
            tray.Dispose();
            Application.Exit();
        }
    }
}
