using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Reflection;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace Parker
{
    /// <summary>
    /// Self-update from GitHub Releases (same repository as the Mac app).
    /// Each release carries Parker-Windows.zip containing Parker.exe.
    /// </summary>
    internal static class Updater
    {
        public const string Repository = "Sholypro/parker";
        const string AssetName = "Parker-Windows.zip";

        public static Version Current
        {
            get
            {
                var v = Assembly.GetExecutingAssembly().GetName().Version;
                return new Version(v.Major, v.Minor, Math.Max(0, v.Build));
            }
        }

        public static string CurrentText { get { var v = Current; return v.Build > 0 ? v.ToString(3) : v.ToString(2); } }

        sealed class Release
        {
            public string Tag, Body, HtmlUrl, AssetUrl;
            public Version Version;
        }

        public static void CheckInBackgroundIfNeeded()
        {
            if ((DateTime.UtcNow - Settings.Current.LastUpdateCheck).TotalHours < 6) return;
            var t = new Timer { Interval = 8000 };
            t.Tick += (s, e) => { t.Stop(); t.Dispose(); Check(false); };
            t.Start();
        }

        public static void Check(bool userInitiated)
        {
            Task.Run(() => Fetch()).ContinueWith(task =>
            {
                Settings.Current.LastUpdateCheck = DateTime.UtcNow;
                Settings.Current.Save();
                var release = task.IsFaulted ? null : task.Result;
                if (release == null)
                {
                    if (userInitiated) MessageBox.Show("Impossible de joindre GitHub. Vérifie ta connexion et réessaie.", "Parker", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }
                if (release.Version <= Current)
                {
                    if (userInitiated) MessageBox.Show("Parker est à jour (version " + CurrentText + ").", "Parker", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }
                if (!userInitiated && Settings.Current.SkippedVersion == release.Tag) return;
                Offer(release);
            }, TaskScheduler.FromCurrentSynchronizationContext());
        }

        static Release Fetch()
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            using (var http = new HttpClient())
            {
                http.Timeout = TimeSpan.FromSeconds(20);
                http.DefaultRequestHeaders.UserAgent.ParseAdd("Parker-Windows/" + CurrentText);
                http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
                var json = http.GetStringAsync("https://api.github.com/repos/" + Repository + "/releases/latest").Result;
                var tag = JsonString(json, "tag_name");
                if (tag == null) return null;
                var assetUrl = Regex.Matches(json, "\"browser_download_url\"\\s*:\\s*\"([^\"]+)\"")
                    .Cast<Match>().Select(m => m.Groups[1].Value)
                    .FirstOrDefault(u => u.EndsWith("/" + AssetName, StringComparison.OrdinalIgnoreCase));
                Version v;
                if (!Version.TryParse(tag.TrimStart('v', 'V'), out v)) return null;
                v = new Version(v.Major, v.Minor, Math.Max(0, v.Build));
                return new Release { Tag = tag, Version = v, Body = JsonString(json, "body") ?? "", HtmlUrl = JsonString(json, "html_url"), AssetUrl = assetUrl };
            }
        }

        /// <summary>Minimal JSON string extraction (first occurrence of the key).</summary>
        static string JsonString(string json, string key)
        {
            var m = Regex.Match(json, "\"" + Regex.Escape(key) + "\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\"");
            if (!m.Success) return null;
            return Regex.Unescape(m.Groups[1].Value);
        }

        static void Offer(Release r)
        {
            var notes = r.Body.Trim();
            if (notes.Length > 700) notes = notes.Substring(0, 700) + "…";
            var text = "Parker " + r.Version.ToString(2) + " est disponible (tu as la " + CurrentText + ").\n\n" + notes +
                       "\n\nOui : installer et relancer\nNon : plus tard\nAnnuler : ignorer cette version";
            var answer = MessageBox.Show(text, "Mise à jour de Parker", MessageBoxButtons.YesNoCancel, MessageBoxIcon.Information);
            if (answer == DialogResult.Cancel) { Settings.Current.SkippedVersion = r.Tag; Settings.Current.Save(); return; }
            if (answer != DialogResult.Yes) return;
            if (string.IsNullOrEmpty(r.AssetUrl)) { Process.Start(new ProcessStartInfo(r.HtmlUrl) { UseShellExecute = true }); return; }
            Toast.Show("Téléchargement de la mise à jour…", 4000);
            Task.Run(() => Download(r.AssetUrl)).ContinueWith(t =>
            {
                if (t.IsFaulted || t.Result == null) { MessageBox.Show("Le téléchargement a échoué.", "Parker", MessageBoxButtons.OK, MessageBoxIcon.Warning); return; }
                Install(t.Result);
            }, TaskScheduler.FromCurrentSynchronizationContext());
        }

        static string Download(string url)
        {
            var work = Path.Combine(Path.GetTempPath(), "ParkerUpdate-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(work);
            var zip = Path.Combine(work, AssetName);
            using (var http = new HttpClient())
            {
                http.Timeout = TimeSpan.FromMinutes(5);
                http.DefaultRequestHeaders.UserAgent.ParseAdd("Parker-Windows/" + CurrentText);
                var bytes = http.GetByteArrayAsync(url).Result;
                File.WriteAllBytes(zip, bytes);
            }
            var outDir = Path.Combine(work, "out");
            ZipFile.ExtractToDirectory(zip, outDir);
            var exe = Directory.GetFiles(outDir, "Parker.exe", SearchOption.AllDirectories).FirstOrDefault();
            return exe;
        }

        /// <summary>Swaps Parker.exe once this process has exited, then relaunches it.</summary>
        static void Install(string newExe)
        {
            var current = Application.ExecutablePath;
            var script = Path.Combine(Path.GetDirectoryName(newExe), "update.cmd");
            var pid = Process.GetCurrentProcess().Id;
            File.WriteAllText(script,
                "@echo off\r\n" +
                ":wait\r\n" +
                "tasklist /FI \"PID eq " + pid + "\" | find \"" + pid + "\" >nul && (timeout /t 1 /nobreak >nul & goto wait)\r\n" +
                "copy /Y \"" + newExe + "\" \"" + current + "\" >nul\r\n" +
                "start \"\" \"" + current + "\"\r\n");
            Process.Start(new ProcessStartInfo("cmd.exe", "/c \"" + script + "\"") { CreateNoWindow = true, UseShellExecute = false, WindowStyle = ProcessWindowStyle.Hidden });
            Application.Exit();
        }
    }
}
