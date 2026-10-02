using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Windows.Forms;

namespace Parker
{
    /// <summary>
    /// CleanShot-style quick access overlay: a stack of floating previews in a screen corner
    /// (bottom-left by default), newest at the bottom. Hover: Copy / Annotate + corner actions.
    /// Click: annotate. Drag: drop the file in any app. Right-click: full menu.
    /// </summary>
    internal static class ThumbnailStack
    {
        static readonly List<ThumbnailForm> cards = new List<ThumbnailForm>();
        public static Action<string> OnEdit;
        public static Action<string> OnPin;

        public static void Show(string path)
        {
            if (path == null || !Settings.Current.ShowThumbnail) return;
            var card = new ThumbnailForm(path);
            if (card.IsEmpty) { card.Dispose(); return; }
            cards.Add(card);
            card.FormClosed += (s, e) => { cards.Remove(card); Layout(true); };
            Layout(false, card);
            card.Show();
            card.SlideIn();
            while (cards.Count > 6) cards[0].Dismiss();
        }

        public static void CloseAll()
        {
            foreach (var c in cards.ToList()) c.Dismiss();
        }

        static bool Left { get { return Settings.Current.ThumbnailPosition != "bottomRight"; } }

        internal static void Layout(bool animate, ThumbnailForm newest = null)
        {
            if (cards.Count == 0) return;
            var screen = Screen.FromPoint(Cursor.Position).WorkingArea;
            var s = Dpi.ForRect(screen);
            var pad = (int)(14 * s); var gap = (int)(10 * s);
            var y = screen.Bottom - pad;
            for (var i = cards.Count - 1; i >= 0; i--)
            {
                var c = cards[i];
                y -= c.Height;
                var x = Left ? screen.Left + pad : screen.Right - pad - c.Width;
                if (y < screen.Top + pad) { c.Dismiss(); continue; }
                c.Target = new Point(x, y);
                if (c == newest) c.Location = new Point(Left ? screen.Left - c.Width - 20 : screen.Right + 20, y);
                else if (!animate) c.Location = c.Target;
                else c.AnimateTo(c.Target);
                y -= gap;
            }
        }

        internal static void Edit(string path) { if (OnEdit != null) OnEdit(path); }
        internal static void Pin(string path) { if (OnPin != null) OnPin(path); }
    }

    internal sealed class ThumbnailForm : ScrollCapture.FloatingForm
    {
        readonly string path;
        readonly Bitmap thumb;
        readonly float scale;
        readonly Timer dismissTimer = new Timer();
        readonly Timer animTimer = new Timer { Interval = 12 };
        Point animFrom, animTo;
        int animStep;
        bool hovering, dismissing;
        Point? mouseDownAt;
        string hot; // name of the hovered button

        public Point Target;
        public bool IsEmpty { get { return thumb == null; } }

        Dictionary<string, Rectangle> buttons = new Dictionary<string, Rectangle>();

        public ThumbnailForm(string path)
        {
            this.path = path;
            var screen = Screen.FromPoint(Cursor.Position).WorkingArea;
            scale = Dpi.ForRect(screen);
            using (var full = ImageStore.LoadUnlocked(path))
            {
                if (full == null) return;
                var w = (int)(180 * scale);
                var aspect = (float)full.Height / full.Width;
                var h = (int)Math.Min(Math.Max(w * aspect, 96 * scale), 200 * scale);
                Size = new Size(w, h);
                thumb = MakeThumb(full, Size);
            }
            Region = new Region(SelectorForm.RoundedRect(new RectangleF(0, 0, Width, Height), 12 * scale));
            Cursor = Cursors.Hand;
            LayoutButtons();

            dismissTimer.Interval = (int)(Settings.Current.ThumbnailSeconds * 1000);
            dismissTimer.Tick += (s, e) => { if (!hovering && Settings.Current.ThumbnailAutoHide) Dismiss(); };
            animTimer.Tick += (s, e) => AnimTick();
        }

        static Bitmap MakeThumb(Bitmap full, Size card)
        {
            // Aspect-fill: tall captures (scrolling) show their top part
            var target = (float)card.Height / card.Width;
            var src = new Rectangle(0, 0, full.Width, full.Height);
            if ((float)full.Height / full.Width > target) src.Height = (int)(full.Width * target);
            else { src.Width = (int)(full.Height / target); src.X = (full.Width - src.Width) / 2; }
            var bmp = new Bitmap(card.Width, card.Height);
            using (var g = Graphics.FromImage(bmp))
            {
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.DrawImage(full, new Rectangle(Point.Empty, card), src, GraphicsUnit.Pixel);
            }
            return bmp;
        }

        void LayoutButtons()
        {
            var s = scale;
            var pillW = (int)(108 * s); var pillH = (int)(28 * s); var gap = (int)(8 * s);
            var compact = Height < 130 * s;
            if (compact)
            {
                var w = (int)Math.Min(90 * s, (Width - 3 * gap) / 2);
                buttons["copy"] = new Rectangle(Width / 2 - w - gap / 2, Height / 2 - pillH / 2, w, pillH);
                buttons["edit"] = new Rectangle(Width / 2 + gap / 2, Height / 2 - pillH / 2, w, pillH);
            }
            else
            {
                buttons["copy"] = new Rectangle(Width / 2 - pillW / 2, Height / 2 - gap / 2 - pillH, pillW, pillH);
                buttons["edit"] = new Rectangle(Width / 2 - pillW / 2, Height / 2 + gap / 2, pillW, pillH);
            }
            var c = (int)(24 * s); var m = (int)(7 * s);
            buttons["close"] = new Rectangle(m, m, c, c);
            buttons["pin"] = new Rectangle(Width - m - c, m, c, c);
            buttons["folder"] = new Rectangle(m, Height - m - c, c, c);
            buttons["delete"] = new Rectangle(Width - m - c, Height - m - c, c, c);
        }

        public void SlideIn()
        {
            AnimateTo(Target);
            dismissTimer.Start();
        }

        public void AnimateTo(Point to)
        {
            animFrom = Location; animTo = to; animStep = 0;
            animTimer.Start();
        }

        void AnimTick()
        {
            animStep++;
            var t = Math.Min(1.0, animStep / 18.0);
            var e = 1 - Math.Pow(1 - t, 3); // ease out
            Location = new Point((int)(animFrom.X + (animTo.X - animFrom.X) * e), (int)(animFrom.Y + (animTo.Y - animFrom.Y) * e));
            if (t >= 1)
            {
                animTimer.Stop();
                if (dismissing) Close();
            }
        }

        public void Dismiss()
        {
            if (dismissing) return;
            dismissing = true;
            dismissTimer.Stop();
            var screen = Screen.FromPoint(Location).WorkingArea;
            var left = Settings.Current.ThumbnailPosition != "bottomRight";
            AnimateTo(new Point(left ? screen.Left - Width - 30 : screen.Right + 30, Top));
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
            if (thumb != null) g.DrawImageUnscaled(thumb, 0, 0);
            using (var border = new Pen(Color.FromArgb(50, 255, 255, 255), 1))
            using (var path = SelectorForm.RoundedRect(new RectangleF(0.5f, 0.5f, Width - 1, Height - 1), 12 * scale))
                g.DrawPath(border, path);

            if (!hovering) return;
            using (var veil = new SolidBrush(Color.FromArgb(110, 0, 0, 0))) g.FillRectangle(veil, ClientRectangle);
            DrawPill(g, "copy", "Copier");
            DrawPill(g, "edit", "Annoter");
            DrawCorner(g, "close", "✕");
            DrawCorner(g, "pin", "📌");
            DrawCorner(g, "folder", "📁");
            DrawCorner(g, "delete", "🗑");
        }

        void DrawPill(Graphics g, string key, string text)
        {
            var r = buttons[key];
            using (var path = SelectorForm.RoundedRect(r, r.Height / 2f))
            using (var bg = new SolidBrush(hot == key ? Color.White : Color.FromArgb(235, 255, 255, 255)))
                g.FillPath(bg, path);
            using (var f = new Font("Segoe UI", 9f, FontStyle.Bold))
            using (var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                g.DrawString(text, f, Brushes.Black, r, sf);
        }

        void DrawCorner(Graphics g, string key, string glyph)
        {
            var r = buttons[key];
            using (var bg = new SolidBrush(hot == key ? Color.FromArgb(230, 0x21, 0x55, 0xFF) : Color.FromArgb(160, 0, 0, 0)))
                g.FillEllipse(bg, r);
            using (var f = new Font("Segoe UI Emoji", 7.5f))
            using (var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                g.DrawString(glyph, f, Brushes.White, r, sf);
        }

        string HitButton(Point p)
        {
            foreach (var kv in buttons) if (kv.Value.Contains(p)) return kv.Key;
            return null;
        }

        protected override void OnMouseEnter(EventArgs e) { hovering = true; Invalidate(); base.OnMouseEnter(e); }

        protected override void OnMouseLeave(EventArgs e)
        {
            hovering = false; hot = null; Invalidate();
            dismissTimer.Stop(); dismissTimer.Start(); // restart the countdown
            base.OnMouseLeave(e);
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            var h = HitButton(e.Location);
            if (h != hot) { hot = h; Invalidate(); }
            if (mouseDownAt.HasValue && e.Button == MouseButtons.Left)
            {
                var d = mouseDownAt.Value;
                if (Math.Abs(e.X - d.X) + Math.Abs(e.Y - d.Y) > 6)
                {
                    mouseDownAt = null;
                    var data = new DataObject();
                    data.SetFileDropList(new System.Collections.Specialized.StringCollection { path });
                    data.SetImage(thumb);
                    var result = DoDragDrop(data, DragDropEffects.Copy | DragDropEffects.Move | DragDropEffects.Link);
                    if (result != DragDropEffects.None) Dismiss();
                }
            }
            base.OnMouseMove(e);
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left) mouseDownAt = e.Location;
            base.OnMouseDown(e);
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            var wasClick = mouseDownAt.HasValue;
            mouseDownAt = null;
            if (e.Button == MouseButtons.Right) { ShowMenu(e.Location); return; }
            if (!wasClick || e.Button != MouseButtons.Left) return;
            switch (HitButton(e.Location))
            {
                case "copy": ImageStore.CopyFile(path); Toast.Show("Copié dans le presse-papiers"); Dismiss(); break;
                case "edit": case null: Close(); ThumbnailStack.Edit(path); break;
                case "close": Dismiss(); break;
                case "pin": Dismiss(); ThumbnailStack.Pin(path); break;
                case "folder": Reveal(path); break;
                case "delete": Delete(); break;
            }
        }

        void ShowMenu(Point at)
        {
            var menu = new ContextMenuStrip();
            menu.Items.Add("Annoter", null, (s, e) => { Close(); ThumbnailStack.Edit(path); });
            menu.Items.Add("Copier", null, (s, e) => { ImageStore.CopyFile(path); Toast.Show("Copié dans le presse-papiers"); });
            menu.Items.Add("Enregistrer sous…", null, (s, e) => SaveAs());
            menu.Items.Add("Épingler à l'écran", null, (s, e) => { Dismiss(); ThumbnailStack.Pin(path); });
            menu.Items.Add("Afficher dans l'Explorateur", null, (s, e) => Reveal(path));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Supprimer", null, (s, e) => Delete());
            menu.Items.Add("Fermer", null, (s, e) => Dismiss());
            menu.Items.Add("Tout fermer", null, (s, e) => ThumbnailStack.CloseAll());
            menu.Show(this, at);
        }

        void SaveAs()
        {
            using (var dlg = new SaveFileDialog { FileName = Path.GetFileName(path), Filter = "PNG|*.png|JPEG|*.jpg" })
            {
                if (dlg.ShowDialog() != DialogResult.OK) return;
                try { File.Copy(path, dlg.FileName, true); Toast.Show("Enregistré : " + Path.GetFileName(dlg.FileName)); }
                catch { Toast.Show("Échec de l'enregistrement"); }
            }
        }

        void Delete()
        {
            try
            {
                if (RecycleBin.Send(path)) Toast.Show("Capture placée dans la corbeille");
                else Toast.Show("Impossible de supprimer le fichier");
            }
            catch { Toast.Show("Impossible de supprimer le fichier"); }
            Dismiss();
        }

        internal static void Reveal(string file)
        {
            try { Process.Start("explorer.exe", "/select,\"" + file + "\""); } catch { }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                dismissTimer.Dispose(); animTimer.Dispose();
                if (thumb != null) thumb.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}
