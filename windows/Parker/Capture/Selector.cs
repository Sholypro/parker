using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Linq;
using System.Text;
using System.Windows.Forms;

namespace Parker
{
    internal enum SelectMode { Area, Window }

    /// <summary>
    /// Full-screen selection overlay (one borderless window per monitor), CleanShot style:
    /// the screen is frozen, everything outside the selection is dimmed, with a magnifier and
    /// a size label. In Window mode the window under the cursor is highlighted and picked on click.
    /// The result is a rectangle in virtual-screen coordinates plus the frozen snapshot.
    /// </summary>
    internal sealed class Selector
    {
        public delegate void Done(Rectangle? rect, Bitmap snapshot);

        readonly SelectMode mode;
        readonly Done done;
        readonly Bitmap snapshot;
        readonly List<SelectorForm> forms = new List<SelectorForm>();
        readonly List<KeyValuePair<IntPtr, Rectangle>> windows;
        bool finished;

        public static void Show(SelectMode mode, Done done)
        {
            var sel = new Selector(mode, done);
            sel.Open();
        }

        Selector(SelectMode mode, Done done)
        {
            this.mode = mode;
            this.done = done;
            snapshot = ScreenGrab.CaptureVirtualScreen();
            windows = mode == SelectMode.Window ? WindowList() : new List<KeyValuePair<IntPtr, Rectangle>>();
        }

        void Open()
        {
            foreach (var screen in Screen.AllScreens)
            {
                var f = new SelectorForm(this, screen);
                forms.Add(f);
                f.Show();
            }
            // Focus the form under the cursor so Esc works immediately
            var under = forms.FirstOrDefault(f => f.Bounds.Contains(Cursor.Position)) ?? forms.FirstOrDefault();
            if (under != null)
            {
                under.Activate();
                Native.SetForegroundWindow(under.Handle);
            }
        }

        internal SelectMode Mode { get { return mode; } }
        internal Bitmap Snapshot { get { return snapshot; } }

        internal Rectangle? WindowAt(Point p)
        {
            foreach (var w in windows)
                if (w.Value.Contains(p)) return w.Value;
            return null;
        }

        internal void Finish(Rectangle? rect)
        {
            if (finished) return;
            finished = true;
            foreach (var f in forms) { f.Hide(); }
            foreach (var f in forms) { f.Dispose(); }
            forms.Clear();
            done(rect, snapshot);
        }

        internal void RefreshAll()
        {
            foreach (var f in forms) f.Invalidate();
        }

        /// <summary>Visible top-level windows in z-order (front first), excluding Parker's own.</summary>
        static List<KeyValuePair<IntPtr, Rectangle>> WindowList()
        {
            var list = new List<KeyValuePair<IntPtr, Rectangle>>();
            var ownPid = (uint)Process.GetCurrentProcess().Id;
            var cls = new StringBuilder(256);
            Native.EnumWindows((h, l) =>
            {
                if (!Native.IsWindowVisible(h) || Native.IsIconic(h) || Native.IsCloaked(h)) return true;
                uint pid;
                Native.GetWindowThreadProcessId(h, out pid);
                if (pid == ownPid) return true;
                var ex = Native.GetWindowLong(h, Native.GWL_EXSTYLE);
                if ((ex & Native.WS_EX_TOOLWINDOW) != 0 && Native.GetWindowTextLength(h) == 0) return true;
                cls.Clear();
                Native.GetClassName(h, cls, cls.Capacity);
                var c = cls.ToString();
                if (c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd" || c == "Shell_SecondaryTrayWnd") return true;
                var r = Native.WindowBounds(h);
                if (r.Width < 40 || r.Height < 30) return true;
                list.Add(new KeyValuePair<IntPtr, Rectangle>(h, r));
                return true;
            }, IntPtr.Zero);
            return list;
        }
    }

    internal sealed class SelectorForm : Form
    {
        readonly Selector owner;
        readonly Screen screen;
        Point? dragStart;      // virtual coords
        Point current;         // virtual coords
        Rectangle? selection;  // virtual coords
        bool spaceMoving;
        Point lastMove;
        Rectangle? hoverWindow;
        Bitmap bright, dimmed; // this monitor's part of the snapshot, plain and darkened

        static readonly Color Accent = Color.FromArgb(0x21, 0x55, 0xFF);

        public SelectorForm(Selector owner, Screen screen)
        {
            this.owner = owner;
            this.screen = screen;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            AutoScaleMode = AutoScaleMode.None;
            TopMost = true;
            KeyPreview = true;
            Cursor = Cursors.Cross;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint, true);
            Bounds = screen.Bounds;
            current = Cursor.Position;
        }

        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                cp.ExStyle |= Native.WS_EX_TOOLWINDOW | Native.WS_EX_TOPMOST;
                return cp;
            }
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            Bounds = screen.Bounds; // re-apply in case a DPI change resized the window
            Native.ExcludeFromCapture(Handle);
        }

        void EnsureBackgrounds()
        {
            if (bright != null) return;
            var vs = ScreenGrab.VirtualScreen;
            var src = new Rectangle(screen.Bounds.X - vs.X, screen.Bounds.Y - vs.Y, screen.Bounds.Width, screen.Bounds.Height);
            bright = new Bitmap(src.Width, src.Height, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
            using (var g = Graphics.FromImage(bright))
                g.DrawImage(owner.Snapshot, new Rectangle(0, 0, src.Width, src.Height), src, GraphicsUnit.Pixel);
            dimmed = new Bitmap(src.Width, src.Height, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
            using (var g = Graphics.FromImage(dimmed))
            using (var dim = new SolidBrush(Color.FromArgb(110, 0, 0, 0)))
            {
                g.DrawImageUnscaled(bright, 0, 0);
                g.FillRectangle(dim, 0, 0, src.Width, src.Height);
            }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                if (bright != null) bright.Dispose();
                if (dimmed != null) dimmed.Dispose();
            }
            base.Dispose(disposing);
        }

        Point ToVirtual(Point client) { return new Point(client.X + Bounds.X, client.Y + Bounds.Y); }
        Rectangle ToClient(Rectangle v) { return new Rectangle(v.X - Bounds.X, v.Y - Bounds.Y, v.Width, v.Height); }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Escape) { owner.Finish(null); return; }
            if (e.KeyCode == Keys.Space && dragStart.HasValue) { spaceMoving = true; lastMove = Cursor.Position; }
            if (e.KeyCode == Keys.Enter && owner.Mode == SelectMode.Area)
            {
                // Enter = whole screen under the cursor
                owner.Finish(screen.Bounds);
            }
            base.OnKeyDown(e);
        }

        protected override void OnKeyUp(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Space) spaceMoving = false;
            base.OnKeyUp(e);
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Right) { owner.Finish(null); return; }
            if (e.Button != MouseButtons.Left) return;
            dragStart = ToVirtual(e.Location);
            current = dragStart.Value;
            selection = null;
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            var p = ToVirtual(e.Location);
            if (dragStart.HasValue && spaceMoving)
            {
                var dx = p.X - lastMove.X; var dy = p.Y - lastMove.Y;
                dragStart = new Point(dragStart.Value.X + dx, dragStart.Value.Y + dy);
                current = new Point(current.X + dx, current.Y + dy);
                lastMove = p;
            }
            else
            {
                current = p;
            }

            if (dragStart.HasValue)
            {
                var s = dragStart.Value;
                var r = Rectangle.FromLTRB(Math.Min(s.X, current.X), Math.Min(s.Y, current.Y), Math.Max(s.X, current.X), Math.Max(s.Y, current.Y));
                if ((ModifierKeys & Keys.Shift) != 0)
                {
                    var side = Math.Max(r.Width, r.Height);
                    r = new Rectangle(current.X >= s.X ? s.X : s.X - side, current.Y >= s.Y ? s.Y : s.Y - side, side, side);
                }
                selection = r;
            }
            else if (owner.Mode == SelectMode.Window)
            {
                hoverWindow = owner.WindowAt(p);
            }
            owner.RefreshAll();
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            if (e.Button != MouseButtons.Left) return;
            var sel = selection;
            dragStart = null;
            if (sel.HasValue && sel.Value.Width > 3 && sel.Value.Height > 3)
            {
                owner.Finish(sel);
            }
            else if (owner.Mode == SelectMode.Window)
            {
                var w = owner.WindowAt(ToVirtual(e.Location));
                owner.Finish(w);
            }
            else
            {
                selection = null;
                owner.RefreshAll();
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            EnsureBackgrounds();
            g.CompositingMode = CompositingMode.SourceCopy;
            g.DrawImageUnscaled(dimmed, 0, 0);
            g.CompositingMode = CompositingMode.SourceOver;

            Rectangle? highlight = selection;
            if (!highlight.HasValue && owner.Mode == SelectMode.Window) highlight = hoverWindow;

            if (highlight.HasValue)
            {
                var hr = ToClient(highlight.Value);
                hr.Intersect(new Rectangle(0, 0, Width, Height));
                if (hr.Width > 0 && hr.Height > 0) g.DrawImage(bright, hr, hr, GraphicsUnit.Pixel);
            }

            g.SmoothingMode = SmoothingMode.AntiAlias;
            if (highlight.HasValue)
            {
                var r = ToClient(highlight.Value);
                using (var pen = new Pen(owner.Mode == SelectMode.Window && !selection.HasValue ? Accent : Color.White, 1.5f))
                    g.DrawRectangle(pen, r);
                DrawSizeLabel(g, highlight.Value, r);
            }

            var cursor = PointToClient(Cursor.Position);
            if (ClientRectangle.Contains(cursor))
            {
                if (!dragStart.HasValue && owner.Mode == SelectMode.Area)
                {
                    using (var pen = new Pen(Color.FromArgb(120, 255, 255, 255), 1))
                    {
                        g.SmoothingMode = SmoothingMode.None;
                        g.DrawLine(pen, 0, cursor.Y, Width, cursor.Y);
                        g.DrawLine(pen, cursor.X, 0, cursor.X, Height);
                    }
                }
                DrawLoupe(g, cursor);
            }

            if (!dragStart.HasValue && ClientRectangle.Contains(cursor))
            {
                var hint = owner.Mode == SelectMode.Area
                    ? "Glisse pour sélectionner · Entrée : écran entier · Échap : annuler"
                    : "Clique sur une fenêtre · Échap : annuler";
                DrawPill(g, hint, new Point(Width / 2, Height - 60), true);
            }
        }

        void DrawSizeLabel(Graphics g, Rectangle v, Rectangle r)
        {
            var text = v.Width + " × " + v.Height;
            var p = new Point(r.Left + 4, r.Bottom + 8);
            if (p.Y + 28 > Height) p = new Point(r.Left + 4, r.Top - 34);
            DrawPill(g, text, p, false);
        }

        void DrawPill(Graphics g, string text, Point anchor, bool centered)
        {
            using (var font = new Font("Segoe UI", 9.5f, FontStyle.Bold, GraphicsUnit.Point))
            {
                var size = g.MeasureString(text, font);
                var rect = new RectangleF(centered ? anchor.X - size.Width / 2 - 10 : anchor.X, anchor.Y, size.Width + 20, size.Height + 10);
                using (var path = RoundedRect(rect, rect.Height / 2))
                using (var bg = new SolidBrush(Color.FromArgb(200, 20, 20, 24)))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.FillPath(bg, path);
                }
                g.DrawString(text, font, Brushes.White, rect.X + 10, rect.Y + 5);
            }
        }

        void DrawLoupe(Graphics g, Point cursor)
        {
            const int zoom = 8, srcSize = 15, size = srcSize * zoom;
            var vs = ScreenGrab.VirtualScreen;
            var v = ToVirtual(cursor);
            var src = new Rectangle(v.X - vs.X - srcSize / 2, v.Y - vs.Y - srcSize / 2, srcSize, srcSize);
            var x = cursor.X + 24; var y = cursor.Y + 24;
            if (x + size > Width) x = cursor.X - 24 - size;
            if (y + size + 26 > Height) y = cursor.Y - 24 - size - 26;
            var dest = new Rectangle(x, y, size, size);

            var state = g.Save();
            using (var clip = new GraphicsPath())
            {
                clip.AddEllipse(dest);
                g.SetClip(clip);
                g.InterpolationMode = InterpolationMode.NearestNeighbor;
                g.PixelOffsetMode = PixelOffsetMode.Half;
                g.Clear(Color.Black);
                g.DrawImage(owner.Snapshot, dest, src, GraphicsUnit.Pixel);
                using (var pen = new Pen(Color.FromArgb(160, Accent), 1))
                {
                    g.DrawRectangle(pen, dest.X + size / 2 - zoom / 2, dest.Y + size / 2 - zoom / 2, zoom, zoom);
                }
            }
            g.Restore(state);
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (var pen = new Pen(Color.White, 2)) g.DrawEllipse(pen, dest);

            var label = v.X + ", " + v.Y;
            using (var font = new Font("Consolas", 8.5f, FontStyle.Regular, GraphicsUnit.Point))
            {
                var ls = g.MeasureString(label, font);
                var lr = new RectangleF(dest.X + size / 2f - ls.Width / 2 - 6, dest.Bottom + 4, ls.Width + 12, ls.Height + 4);
                using (var bg = new SolidBrush(Color.FromArgb(200, 20, 20, 24))) g.FillRectangle(bg, lr);
                g.DrawString(label, font, Brushes.White, lr.X + 6, lr.Y + 2);
            }
        }

        internal static GraphicsPath RoundedRect(RectangleF r, float radius)
        {
            var path = new GraphicsPath();
            var d = Math.Max(1f, Math.Min(radius * 2, Math.Min(r.Width, r.Height)));
            path.AddArc(r.X, r.Y, d, d, 180, 90);
            path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }
    }
}
