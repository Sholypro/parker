using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace Parker
{
    /// <summary>Small pill notification at the bottom of the screen.</summary>
    internal sealed class Toast : ScrollCapture.FloatingForm
    {
        static Toast current;
        readonly string text;
        readonly Timer timer = new Timer();
        readonly float scale;

        public static void Show(string message, int milliseconds = 1800)
        {
            if (current != null && !current.IsDisposed) current.Close();
            current = new Toast(message, milliseconds);
            current.Show();
        }

        Toast(string message, int ms)
        {
            text = message;
            var area = Screen.FromPoint(Cursor.Position).WorkingArea;
            scale = Dpi.ForRect(area);
            BackColor = Color.FromArgb(28, 28, 32);
            using (var f = new Font("Segoe UI", 10f, FontStyle.Bold))
            using (var g = CreateGraphics())
            {
                var size = g.MeasureString(text, f);
                var w = (int)(size.Width * scale / (g.DpiX / 96f) + 40 * scale);
                var h = (int)(38 * scale);
                Bounds = new Rectangle(area.Left + area.Width / 2 - w / 2, area.Bottom - h - (int)(60 * scale), w, h);
            }
            Region = new Region(SelectorForm.RoundedRect(new RectangleF(0, 0, Width, Height), Height / 2f));
            timer.Interval = ms;
            timer.Tick += (s, e) => { timer.Stop(); Close(); };
            timer.Start();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
            using (var f = new Font("Segoe UI", 10f, FontStyle.Bold))
            using (var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                e.Graphics.DrawString(text, f, Brushes.White, ClientRectangle, sf);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) timer.Dispose();
            base.Dispose(disposing);
        }
    }

    /// <summary>Screenshot pinned above every window. Drag to move, wheel to zoom, Ctrl+wheel for opacity,
    /// double-click or Esc to close, right-click for the menu.</summary>
    internal sealed class PinForm : Form
    {
        readonly Bitmap image;
        readonly string path;
        float zoom = 1f;
        Point dragOffset;
        bool dragging;

        public PinForm(string path)
        {
            this.path = path;
            image = ImageStore.LoadUnlocked(path);
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            AutoScaleMode = AutoScaleMode.None;
            KeyPreview = true;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint, true);
            if (image == null) return;

            var area = Screen.FromPoint(Cursor.Position).WorkingArea;
            // Keep it reasonably small at first
            zoom = Math.Min(1f, Math.Min(area.Width * 0.5f / image.Width, area.Height * 0.6f / image.Height));
            Size = new Size((int)(image.Width * zoom), (int)(image.Height * zoom));
            Location = new Point(area.Left + area.Width / 2 - Width / 2, area.Top + area.Height / 2 - Height / 2);
        }

        protected override CreateParams CreateParams
        {
            get { var cp = base.CreateParams; cp.ExStyle |= Native.WS_EX_TOOLWINDOW; return cp; }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            if (image == null) return;
            e.Graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            e.Graphics.DrawImage(image, ClientRectangle);
            using (var pen = new Pen(Color.FromArgb(0x21, 0x55, 0xFF), 2)) e.Graphics.DrawRectangle(pen, 1, 1, Width - 2, Height - 2);
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left) { dragging = true; dragOffset = e.Location; }
            if (e.Button == MouseButtons.Right)
            {
                var m = new ContextMenuStrip();
                m.Items.Add("Copier", null, (s, a) => { ImageStore.CopyImage(image); Toast.Show("Copié dans le presse-papiers"); });
                m.Items.Add("Annoter", null, (s, a) => { ThumbnailStack.Edit(path); Close(); });
                m.Items.Add("Taille réelle", null, (s, a) => SetZoom(1f));
                m.Items.Add(new ToolStripSeparator());
                m.Items.Add("Fermer", null, (s, a) => Close());
                m.Show(this, e.Location);
            }
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            if (dragging) Location = new Point(Left + e.X - dragOffset.X, Top + e.Y - dragOffset.Y);
        }

        protected override void OnMouseUp(MouseEventArgs e) { dragging = false; }
        protected override void OnMouseDoubleClick(MouseEventArgs e) { Close(); }

        protected override void OnMouseWheel(MouseEventArgs e)
        {
            if ((ModifierKeys & Keys.Control) != 0)
            {
                Opacity = Math.Max(0.2, Math.Min(1.0, Opacity + (e.Delta > 0 ? 0.1 : -0.1)));
                return;
            }
            SetZoom(zoom * (e.Delta > 0 ? 1.1f : 1 / 1.1f));
        }

        void SetZoom(float z)
        {
            if (image == null) return;
            zoom = Math.Max(0.1f, Math.Min(4f, z));
            var center = new Point(Left + Width / 2, Top + Height / 2);
            Size = new Size(Math.Max(40, (int)(image.Width * zoom)), Math.Max(30, (int)(image.Height * zoom)));
            Location = new Point(center.X - Width / 2, center.Y - Height / 2);
            Invalidate();
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Escape) Close();
            if (e.Control && e.KeyCode == Keys.C) { ImageStore.CopyImage(image); Toast.Show("Copié dans le presse-papiers"); }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing && image != null) image.Dispose();
            base.Dispose(disposing);
        }
    }
}
