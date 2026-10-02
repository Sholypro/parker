using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Parker
{
    /// <summary>
    /// Per-user installation, no admin rights needed. The downloaded Parker.exe copies itself to
    /// %LOCALAPPDATA%\Programs\Parker, adds a Start menu shortcut and an entry in
    /// "Applications installées" (with uninstall), confirms, then starts the installed copy.
    /// The downloaded file can then be deleted.
    /// </summary>
    internal static class Installer
    {
        const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\Parker";

        public static string InstallDir
        {
            get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Parker"); }
        }

        public static string InstalledExe { get { return Path.Combine(InstallDir, "Parker.exe"); } }

        static string StartMenuShortcut
        {
            get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "Parker.lnk"); }
        }

        static string CurrentExe { get { return Application.ExecutablePath; } }

        public static bool IsInstalledCopy
        {
            get { return string.Equals(Path.GetFullPath(CurrentExe), Path.GetFullPath(InstalledExe), StringComparison.OrdinalIgnoreCase); }
        }

        /// <summary>
        /// Called at launch from anywhere else than the install folder.
        /// Returns true when the installed copy was started (this process must exit).
        /// </summary>
        public static bool InstallFromDownload()
        {
            var updating = File.Exists(InstalledExe);
            try
            {
                StopOtherInstances();
                Directory.CreateDirectory(InstallDir);
                CopyWithRetry(CurrentExe, InstalledExe);
                // The copy inherits the "downloaded from the Internet" mark: drop it so Windows
                // does not ask again each time the installed app starts
                DeleteFile(InstalledExe + ":Zone.Identifier");
                Register();
                CreateShortcut(StartMenuShortcut, InstalledExe);
                if (Settings.Current.LaunchAtStartup) Startup.Apply(true, InstalledExe);
            }
            catch (Exception ex)
            {
                var answer = MessageBox.Show(
                    "L'installation de Parker n'a pas pu se terminer :\n" + ex.Message +
                    "\n\nLancer Parker quand même depuis cet emplacement ?",
                    "Installation de Parker", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
                return answer != DialogResult.Yes;
            }

            MessageBox.Show(
                (updating ? "Parker a bien été mis à jour (version " : "Parker a bien été installé (version ") + Updater.CurrentText + ").\n\n" +
                "Tu le retrouves dans le menu Démarrer et près de l'horloge, en bas à droite (icône Parker).\n" +
                "Raccourcis : Ctrl+Maj+4 pour une zone, Ctrl+Maj+6 pour une capture défilante.\n\n" +
                "Tu peux supprimer le fichier que tu as téléchargé.",
                "Parker est installé", MessageBoxButtons.OK, MessageBoxIcon.Information);

            try { Process.Start(new ProcessStartInfo(InstalledExe) { UseShellExecute = true, WorkingDirectory = InstallDir }); }
            catch { }
            return true;
        }

        /// <summary>Keeps the "Applications installées" entry and shortcut in sync (after an update, a move…).</summary>
        public static void RefreshRegistration()
        {
            try
            {
                Register();
                if (!File.Exists(StartMenuShortcut)) CreateShortcut(StartMenuShortcut, InstalledExe);
            }
            catch { }
        }

        public static void Uninstall()
        {
            var answer = MessageBox.Show("Désinstaller Parker ?\n\nTes captures (dossier Images\\Parker) sont conservées.",
                "Désinstaller Parker", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (answer != DialogResult.Yes) return;

            StopOtherInstances();
            Startup.Apply(false);
            try { if (File.Exists(StartMenuShortcut)) File.Delete(StartMenuShortcut); } catch { }
            try { Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, false); } catch { }

            // The running exe cannot delete itself: a hidden command removes the folder once we exit
            var pid = Process.GetCurrentProcess().Id;
            var script = Path.Combine(Path.GetTempPath(), "parker-uninstall.cmd");
            File.WriteAllText(script,
                "@echo off\r\n" +
                ":wait\r\n" +
                "tasklist /FI \"PID eq " + pid + "\" | find \"" + pid + "\" >nul && (timeout /t 1 /nobreak >nul & goto wait)\r\n" +
                "rmdir /s /q \"" + InstallDir + "\"\r\n" +
                "del \"%~f0\"\r\n");
            Process.Start(new ProcessStartInfo("cmd.exe", "/c \"" + script + "\"") { CreateNoWindow = true, UseShellExecute = false, WindowStyle = ProcessWindowStyle.Hidden });

            MessageBox.Show("Parker a été désinstallé.", "Parker", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        // ---------- Internals ----------

        [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
        static extern bool DeleteFile(string name);

        static void StopOtherInstances()
        {
            var me = Process.GetCurrentProcess().Id;
            foreach (var p in Process.GetProcessesByName("Parker"))
            {
                if (p.Id == me) continue;
                try { p.Kill(); p.WaitForExit(4000); } catch { }
            }
        }

        static void CopyWithRetry(string from, string to)
        {
            for (var i = 0; ; i++)
            {
                try { File.Copy(from, to, true); return; }
                catch (IOException) { if (i >= 10) throw; Thread.Sleep(400); }
                catch (UnauthorizedAccessException) { if (i >= 10) throw; Thread.Sleep(400); }
            }
        }

        static void Register()
        {
            using (var key = Registry.CurrentUser.CreateSubKey(UninstallKey))
            {
                if (key == null) return;
                key.SetValue("DisplayName", "Parker");
                key.SetValue("DisplayVersion", Updater.CurrentText);
                key.SetValue("Publisher", "Sholy Design");
                key.SetValue("DisplayIcon", InstalledExe + ",0");
                key.SetValue("InstallLocation", InstallDir);
                key.SetValue("UninstallString", "\"" + InstalledExe + "\" --uninstall");
                key.SetValue("URLInfoAbout", "https://github.com/" + Updater.Repository);
                key.SetValue("NoModify", 1, RegistryValueKind.DWord);
                key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
                try
                {
                    var kb = (int)(new FileInfo(InstalledExe).Length / 1024);
                    key.SetValue("EstimatedSize", kb, RegistryValueKind.DWord);
                }
                catch { }
            }
        }

        /// <summary>.lnk through the Windows Script Host COM object (late bound, no interop assembly).</summary>
        static void CreateShortcut(string lnkPath, string target)
        {
            var type = Type.GetTypeFromProgID("WScript.Shell");
            if (type == null) return;
            var shell = Activator.CreateInstance(type);
            try
            {
                var lnk = type.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { lnkPath });
                var lt = lnk.GetType();
                lt.InvokeMember("TargetPath", BindingFlags.SetProperty, null, lnk, new object[] { target });
                lt.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, lnk, new object[] { Path.GetDirectoryName(target) });
                lt.InvokeMember("IconLocation", BindingFlags.SetProperty, null, lnk, new object[] { target + ",0" });
                lt.InvokeMember("Description", BindingFlags.SetProperty, null, lnk, new object[] { "Parker : capture d'écran, annotation, capture défilante" });
                lt.InvokeMember("Save", BindingFlags.InvokeMethod, null, lnk, null);
            }
            finally
            {
                if (System.Runtime.InteropServices.Marshal.IsComObject(shell))
                    System.Runtime.InteropServices.Marshal.ReleaseComObject(shell);
            }
        }
    }
}
