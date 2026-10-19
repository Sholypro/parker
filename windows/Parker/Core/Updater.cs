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

        /// <summary>The "new features" part of the release text as plain lines ("• …"): stops at the
        /// download section and removes Markdown marks (titles, bold, code, [text](link)).</summary>
        static string FeatureNotes(string body)
        {
            var lines = new System.Collections.Generic.List<string>();
            foreach (var raw in (body ?? "").Replace("\r", "").Split('\n'))
            {
                var line = raw.Trim();
                var plain = line.Replace("#", "").Trim().ToLowerInvariant();
                if (plain.StartsWith("télécharger") || plain.StartsWith("premier lancement")) break;
                if (plain.StartsWith("nouveautés")) continue;
                line = Regex.Replace(line, @"\[([^\]]+)\]\([^)]*\)", "$1");
                line = line.Replace("**", "").Replace("__", "").Replace("`", "").TrimStart('#').Trim();
                if (line.StartsWith("- ") || line.StartsWith("* ")) line = "• " + line.Substring(2);
                if (line.Length == 0 && (lines.Count == 0 || lines[lines.Count - 1].Length == 0)) continue;
                lines.Add(line);
            }
            while (lines.Count > 0 && lines[lines.Count - 1].Length == 0) lines.RemoveAt(lines.Count - 1);
            return string.Join("\n", lines);
        }

        static void Offer(Release r)
        {
            var notes = FeatureNotes(r.Body);
            if (notes.Length > 700) notes = notes.Substring(0, 700) + "…";
            var text = "Parker " + r.Version.ToString(2) + " est disponible (tu as la " + CurrentText + ")." +
                       (notes.Length > 0 ? "\n\nNouveautés :\n" + notes : "") +
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
            var current = Installer.CurrentExe;
            var script = Path.Combine(Path.GetDirectoryName(newExe), "update.cmd");
            var pid = Process.GetCurrentProcess().Id;
            // cmd reads scripts in the OEM code page: the script stays pure ASCII and the paths
            // (which contain the user name, possibly accented) go through environment variables
            File.WriteAllText(script,
                "@echo off\r\n" +
                ":wait\r\n" +
                "tasklist /FI \"PID eq %PARKER_PID%\" | find \"%PARKER_PID%\" >nul && (timeout /t 1 /nobreak >nul & goto wait)\r\n" +
                "copy /Y \"%PARKER_NEW%\" \"%PARKER_EXE%\" >nul\r\n" +
                "start \"\" \"%PARKER_EXE%\"\r\n",
                System.Text.Encoding.ASCII);
            var psi = new ProcessStartInfo("cmd.exe", "/c \"" + script + "\"") { CreateNoWindow = true, UseShellExecute = false, WindowStyle = ProcessWindowStyle.Hidden };
            psi.Environment["PARKER_PID"] = pid.ToString();
            psi.Environment["PARKER_NEW"] = newExe;
            psi.Environment["PARKER_EXE"] = current;
            Process.Start(psi);
            Application.Exit();
        }
    }
}
