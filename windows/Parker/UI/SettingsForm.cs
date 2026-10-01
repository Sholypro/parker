using System;
using System.Drawing;
using System.IO;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Parker
{
    internal sealed class SettingsForm : Form
    {
        readonly TextBox folder = new TextBox { Width = 300 };
        readonly ComboBox format = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 120 };
        readonly CheckBox copy = new CheckBox { Text = "Copier automatiquement dans le presse-papiers", AutoSize = true };
        readonly CheckBox thumb = new CheckBox { Text = "Afficher les vignettes flottantes", AutoSize = true };
        readonly ComboBox position = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 160 };
        readonly NumericUpDown seconds = new NumericUpDown { Minimum = 2, Maximum = 60, Width = 60 };
        readonly CheckBox sound = new CheckBox { Text = "Son de capture", AutoSize = true };
        readonly CheckBox startup = new CheckBox { Text = "Lancer Parker au démarrage de Windows", AutoSize = true };

        public SettingsForm(string hotkeysText)
        {
            Text = "Réglages de Parker";
            Icon = TrayApp.AppIcon;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false; MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            AutoScaleDimensions = new SizeF(96F, 96F);
            AutoScaleMode = AutoScaleMode.Dpi;
            Font = new Font("Segoe UI", 9.5f);
            AutoSize = true;
            AutoSizeMode = AutoSizeMode.GrowAndShrink;
            Padding = new Padding(18);

            var s = Settings.Current;
            folder.Text = s.SaveFolder;
            format.Items.AddRange(new object[] { "PNG", "JPEG" });
            format.SelectedIndex = s.ImageFormat == "jpg" ? 1 : 0;
            copy.Checked = s.CopyToClipboard;
            thumb.Checked = s.ShowThumbnail;
            position.Items.AddRange(new object[] { "En bas à gauche", "En bas à droite" });
            position.SelectedIndex = s.ThumbnailPosition == "bottomRight" ? 1 : 0;
            seconds.Value = (decimal)Math.Max(2, Math.Min(60, s.ThumbnailSeconds));
            sound.Checked = s.PlaySound;
            startup.Checked = s.LaunchAtStartup;

            var browse = new Button { Text = "Choisir…", AutoSize = true };
            browse.Click += (o, e) =>
            {
                using (var dlg = new FolderBrowserDialog { SelectedPath = folder.Text })
                    if (dlg.ShowDialog(this) == DialogResult.OK) folder.Text = dlg.SelectedPath;
            };

            var layout = new TableLayoutPanel { ColumnCount = 2, AutoSize = true, Dock = DockStyle.Fill };
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            Action<string, Control> row = (label, control) =>
            {
                layout.Controls.Add(new Label { Text = label, AutoSize = true, Anchor = AnchorStyles.Left, Margin = new Padding(0, 8, 12, 4) });
                layout.Controls.Add(control);
            };
            var folderRow = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0) };
            folderRow.Controls.Add(folder);
            folderRow.Controls.Add(browse);
            row("Dossier des captures", folderRow);
            row("Format", format);
            row("", copy);
            row("", sound);
            row("", thumb);
            row("Position des vignettes", position);
            row("Durée d'affichage (s)", seconds);
            row("", startup);
            row("Raccourcis", new Label { Text = hotkeysText, AutoSize = true, ForeColor = SystemColors.GrayText, Margin = new Padding(0, 8, 0, 4) });

            var ok = new Button { Text = "Enregistrer", AutoSize = true, DialogResult = DialogResult.OK };
            var cancel = new Button { Text = "Annuler", AutoSize = true, DialogResult = DialogResult.Cancel };
            var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Dock = DockStyle.Bottom, Padding = new Padding(0, 12, 0, 0) };
            buttons.Controls.Add(ok);
            buttons.Controls.Add(cancel);
            AcceptButton = ok; CancelButton = cancel;

            var root = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false };
            root.Controls.Add(layout);
            root.Controls.Add(buttons);
            Controls.Add(root);

            ok.Click += (o, e) => Apply();
        }

        void Apply()
        {
            var s = Settings.Current;
            if (!string.IsNullOrWhiteSpace(folder.Text)) s.SaveFolder = folder.Text.Trim();
            s.ImageFormat = format.SelectedIndex == 1 ? "jpg" : "png";
            s.CopyToClipboard = copy.Checked;
            s.ShowThumbnail = thumb.Checked;
            s.ThumbnailPosition = position.SelectedIndex == 1 ? "bottomRight" : "bottomLeft";
            s.ThumbnailSeconds = (double)seconds.Value;
            s.PlaySound = sound.Checked;
            s.LaunchAtStartup = startup.Checked;
            s.Save();
            Startup.Apply(s.LaunchAtStartup);
        }
    }

    internal static class Startup
    {
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

        public static void Apply(bool enabled)
        {
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(RunKey, true))
                {
                    if (key == null) return;
                    if (enabled) key.SetValue("Parker", "\"" + Application.ExecutablePath + "\" --startup");
                    else if (key.GetValue("Parker") != null) key.DeleteValue("Parker");
                }
            }
            catch { }
        }
    }
}
