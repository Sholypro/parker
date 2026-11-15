using System;
using System.Net.Http;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace Parker
{
    /// <summary>
    /// Anonymous usage count, with no server of our own. Once a day, Parker downloads a tiny
    /// text file attached to the latest GitHub release (stats-windows.txt). GitHub counts the
    /// downloads of each release file, so that counter is the number of Windows installations
    /// that ran Parker each day. Nothing is sent: no identifier, no name, no capture.
    /// The "Partager des statistiques anonymes" setting turns it off.
    /// </summary>
    public static class UsagePing
    {
        const string Repository = "Sholypro/parker";
        static Timer timer;

        public static void Start()
        {
            var first = new Timer { Interval = 20000 };
            first.Tick += (s, e) => { first.Stop(); first.Dispose(); PingIfNeeded(); };
            first.Start();
            timer = new Timer { Interval = 3600 * 1000 };
            timer.Tick += (s, e) => PingIfNeeded();
            timer.Start();
        }

        public static void PingIfNeeded()
        {
            var settings = Settings.Current;
            if (!settings.ShareAnonymousStats) return;
            var today = DateTime.UtcNow.ToString("yyyy-MM-dd");
            if (settings.LastUsagePingDay == today) return;

            Task.Run(async () =>
            {
                try
                {
                    using (var http = new HttpClient())
                    {
                        http.Timeout = TimeSpan.FromSeconds(20);
                        http.DefaultRequestHeaders.UserAgent.ParseAdd("Parker/" + Updater.Current + " (Windows)");
                        var response = await http.GetAsync("https://github.com/" + Repository + "/releases/latest/download/stats-windows.txt");
                        if (!response.IsSuccessStatusCode) return;
                    }
                    settings.LastUsagePingDay = today;
                    settings.Save();
                }
                catch
                {
                    // Offline or blocked: try again later
                }
            });
        }
    }
}
