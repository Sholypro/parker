using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;

namespace Parker
{
    /// <summary>
    /// Settings stored as a small key=value file in %APPDATA%\Parker\settings.ini
    /// (no JSON dependency, readable by hand).
    /// </summary>
    internal sealed class Settings
    {
        public static readonly Settings Current = Load();

        static string Dir { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Parker"); } }
        static string FilePath { get { return Path.Combine(Dir, "settings.ini"); } }

        public string SaveFolder = DefaultSaveFolder();
        public string ImageFormat = "png";          // png | jpg
        public int JpegQuality = 90;
        public bool CopyToClipboard = true;
        public bool ShowThumbnail = true;
        public string ThumbnailPosition = "bottomLeft"; // bottomLeft | bottomRight
        public double ThumbnailSeconds = 6;
        public bool PlaySound = true;
        public bool LaunchAtStartup = true;
        public string SkippedVersion = "";
        public DateTime LastUpdateCheck = DateTime.MinValue;
        public List<string> Recent = new List<string>();
        public bool FirstRunDone = false;

        public static string DefaultSaveFolder()
        {
            var pictures = Environment.GetFolderPath(Environment.SpecialFolder.MyPictures);
            if (string.IsNullOrEmpty(pictures)) pictures = Environment.GetFolderPath(Environment.SpecialFolder.Desktop);
            return Path.Combine(pictures, "Parker");
        }

        static Settings Load()
        {
            var s = new Settings();
            try
            {
                if (!File.Exists(FilePath)) return s;
                foreach (var raw in File.ReadAllLines(FilePath, Encoding.UTF8))
                {
                    var i = raw.IndexOf('=');
                    if (i <= 0) continue;
                    var key = raw.Substring(0, i).Trim();
                    var val = raw.Substring(i + 1).Trim();
                    switch (key)
                    {
                        case "SaveFolder": if (val.Length > 0) s.SaveFolder = val; break;
                        case "ImageFormat": s.ImageFormat = val == "jpg" ? "jpg" : "png"; break;
                        case "JpegQuality": int.TryParse(val, out s.JpegQuality); break;
                        case "CopyToClipboard": s.CopyToClipboard = val == "1"; break;
                        case "ShowThumbnail": s.ShowThumbnail = val == "1"; break;
                        case "ThumbnailPosition": s.ThumbnailPosition = val == "bottomRight" ? "bottomRight" : "bottomLeft"; break;
                        case "ThumbnailSeconds": double.TryParse(val, NumberStyles.Float, CultureInfo.InvariantCulture, out s.ThumbnailSeconds); break;
                        case "PlaySound": s.PlaySound = val == "1"; break;
                        case "LaunchAtStartup": s.LaunchAtStartup = val == "1"; break;
                        case "SkippedVersion": s.SkippedVersion = val; break;
                        case "LastUpdateCheck":
                            long ticks;
                            if (long.TryParse(val, out ticks)) s.LastUpdateCheck = new DateTime(ticks, DateTimeKind.Utc);
                            break;
                        case "Recent": s.Recent = val.Split('|').Where(p => p.Length > 0).ToList(); break;
                        case "FirstRunDone": s.FirstRunDone = val == "1"; break;
                    }
                }
            }
            catch { }
            if (s.JpegQuality < 10 || s.JpegQuality > 100) s.JpegQuality = 90;
            if (s.ThumbnailSeconds <= 0) s.ThumbnailSeconds = 6;
            return s;
        }

        public void Save()
        {
            try
            {
                Directory.CreateDirectory(Dir);
                var lines = new[]
                {
                    "SaveFolder=" + SaveFolder,
                    "ImageFormat=" + ImageFormat,
                    "JpegQuality=" + JpegQuality,
                    "CopyToClipboard=" + (CopyToClipboard ? 1 : 0),
                    "ShowThumbnail=" + (ShowThumbnail ? 1 : 0),
                    "ThumbnailPosition=" + ThumbnailPosition,
                    "ThumbnailSeconds=" + ThumbnailSeconds.ToString(CultureInfo.InvariantCulture),
                    "PlaySound=" + (PlaySound ? 1 : 0),
                    "LaunchAtStartup=" + (LaunchAtStartup ? 1 : 0),
                    "SkippedVersion=" + SkippedVersion,
                    "LastUpdateCheck=" + LastUpdateCheck.Ticks,
                    "Recent=" + string.Join("|", Recent.Take(20)),
                    "FirstRunDone=" + (FirstRunDone ? 1 : 0),
                };
                File.WriteAllLines(FilePath, lines, Encoding.UTF8);
            }
            catch { }
        }

        public void AddRecent(string path)
        {
            Recent.Remove(path);
            Recent.Insert(0, path);
            Recent = Recent.Where(File.Exists).Take(20).ToList();
            Save();
        }
    }
}
