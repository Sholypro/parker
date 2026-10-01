using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Windows.Forms;

namespace Parker
{
    /// <summary>Annotation editor window: toolbar, zoomable canvas, save/copy bar.</summary>
    internal sealed class EditorForm : Form
    {
        readonly string filePath;
        readonly Canvas canvas;
        readonly Panel scroller;
        readonly FlowLayoutPanel toolbar;
        readonly Dictionary<Tool, Button> toolButtons = new Dictionary<Tool, Button>();
        readonly List<Button> swatches = new List<Button>();
        readonly Button fillButton;
        readonly TrackBar widthBar;
        readonly Panel cropBar;
        static readonly Color[] Palette =
        {
            Color.FromArgb(255, 59, 48), Color.FromArgb(255, 149, 0), Color.FromArgb(255, 204, 0), Color.FromArgb(52, 199, 89),
            Color.FromArgb(0x21, 0x55, 0xFF), Color.FromArgb(175, 82, 222), Color.Black, Color.White
        };
        static readonly string IconFont = PickIconFont();

        static string PickIconFont()
        {
            using (var f = new Font("Segoe Fluent Icons", 10f))
                if (f.Name == "Segoe Fluent Icons") return "Segoe Fluent Icons";
            return "Segoe MDL2 Assets";
        }

        public EditorForm(string path)
        {
            filePath = path;
            Text = "Annoter · " + Path.GetFileName(path);
            Icon = TrayApp.AppIcon;
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.FromArgb(30, 30, 33);
            ForeColor = Color.White;
            KeyPreview = true;
            AutoScaleDimensions = new SizeF(96F, 96F);
            AutoScaleMode = AutoScaleMode.Dpi;
            Font = new Font("Segoe UI", 9f);
            MinimumSize = new Size(820, 420);

            var image = ImageStore.LoadUnlocked(path) ?? new Bitmap(400, 300);
            canvas = new Canvas(image);

            // ---- Toolbar ----
            toolbar = new FlowLayoutPanel
            {
                Dock = DockStyle.Top,
                Height = 48,
                Padding = new Padding(8, 7, 8, 0),
                BackColor = Color.FromArgb(40, 40, 44),
                WrapContents = false,
                AutoScroll = false,
            };
            foreach (var tool in ToolInfo.Order)
            {
                var t = tool;
                var b = IconButton(ToolInfo.Glyph(t), ToolInfo.Label(t) + " (" + ToolInfo.Key(t) + ")");
                b.Click += (s, e) => SelectTool(t);
                toolButtons[t] = b;
                toolbar.Controls.Add(b);
            }
            toolbar.Controls.Add(Separator());
            for (var i = 0; i < Palette.Length; i++)
            {
                var c = Palette[i];
                var sw = new Button
                {
                    Width = 22, Height = 22, Margin = new Padding(3, 6, 3, 0),
                    FlatStyle = FlatStyle.Flat, BackColor = c, TabStop = false, Cursor = Cursors.Hand,
                };
                sw.FlatAppearance.BorderColor = Color.FromArgb(90, 90, 96);
                sw.Click += (s, e) => { canvas.CurrentColor = c; UpdateSwatches(); };
                swatches.Add(sw);
                toolbar.Controls.Add(sw);
            }
            toolbar.Controls.Add(Separator());
            fillButton = IconButton("", "Remplissage (formes) / Étiquette (texte)");
            fillButton.Click += (s, e) => { canvas.CurrentFilled = !canvas.CurrentFilled; UpdateToggles(); };
            toolbar.Controls.Add(fillButton);
            widthBar = new TrackBar
            {
                Minimum = 1, Maximum = 12, Value = 4, TickStyle = TickStyle.None,
                Width = 90, Margin = new Padding(4, 4, 4, 0), AutoSize = false, Height = 30,
            };
            widthBar.ValueChanged += (s, e) => canvas.CurrentWidth = widthBar.Value;
            toolbar.Controls.Add(widthBar);
            toolbar.Controls.Add(Separator());
            var undo = IconButton("", "Annuler (Ctrl+Z)");
            undo.Click += (s, e) => canvas.Undo();
            var redo = IconButton("", "Rétablir (Ctrl+Y)");
            redo.Click += (s, e) => canvas.Redo();
            toolbar.Controls.Add(undo);
            toolbar.Controls.Add(redo);

            // ---- Canvas ----
            scroller = new Panel { Dock = DockStyle.Fill, AutoScroll = true, BackColor = Color.FromArgb(24, 24, 27) };
            scroller.Controls.Add(canvas);
            scroller.Resize += (s, e) => CenterCanvas();
            canvas.SizeChanged += (s, e) => CenterCanvas();

            // ---- Bottom bar ----
            var bottom = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 46, Padding = new Padding(10, 8, 10, 0), BackColor = Color.FromArgb(40, 40, 44) };
            var copy = TextButton("Copier", "Copier l'image annotée (Ctrl+C)");
            copy.Click += (s, e) => CopyResult();
            var save = TextButton("Enregistrer", "Enregistrer par-dessus la capture (Ctrl+S)");
            save.BackColor = Color.FromArgb(0x21, 0x55, 0xFF);
            save.Click += (s, e) => SaveResult();
            var saveAs = TextButton("Enregistrer sous…", "Enregistrer une copie (Ctrl+Maj+S)");
            saveAs.Click += (s, e) => SaveAs();
            bottom.Controls.AddRange(new Control[] { copy, save, saveAs });

            cropBar = new FlowLayoutPanel { Width = 230, Height = 32, Visible = false, Margin = new Padding(16, 0, 0, 0), BackColor = Color.Transparent };
            var apply = TextButton("Recadrer ↵", "Appliquer le recadrage (Entrée)");
            apply.BackColor = Color.FromArgb(52, 160, 89);
            apply.Click += (s, e) => canvas.ApplyCrop();
            var cancel = TextButton("Annuler", "Annuler le recadrage (Échap)");
            cancel.Click += (s, e) => canvas.CancelCrop();
            cropBar.Controls.Add(apply);
            cropBar.Controls.Add(cancel);
            bottom.Controls.Add(cropBar);

            Controls.Add(scroller);
            Controls.Add(bottom);
            Controls.Add(toolbar);

            canvas.CropPendingChanged += pending => cropBar.Visible = pending;
            canvas.ToolChanged += t => UpdateToolButtons();
            canvas.ImageResized += () => FitZoom();

            // Window size from the image
            var area = Screen.FromPoint(Cursor.Position).WorkingArea;
            var w = Math.Min(area.Width - 80, Math.Max(MinimumSize.Width, image.Width + 60));
            var h = Math.Min(area.Height - 80, Math.Max(MinimumSize.Height, image.Height + 160));
            Size = new Size(w, h);
            FitZoom();
            SelectTool(Tool.Arrow);
            UpdateSwatches();
            UpdateToggles();
        }

        Button IconButton(string glyph, string tip)
        {
            var b = new Button
            {
                Text = glyph, Font = new Font(IconFont, 12f), Width = 34, Height = 32, Margin = new Padding(1, 0, 1, 0),
                FlatStyle = FlatStyle.Flat, ForeColor = Color.White, BackColor = Color.Transparent, TabStop = false, Cursor = Cursors.Hand,
            };
            b.FlatAppearance.BorderSize = 0;
            b.FlatAppearance.MouseOverBackColor = Color.FromArgb(62, 62, 68);
            new ToolTip().SetToolTip(b, tip);
            return b;
        }

        Button TextButton(string text, string tip)
        {
            var b = new Button
            {
                Text = text, AutoSize = true, Height = 30, Padding = new Padding(8, 0, 8, 0), Margin = new Padding(0, 0, 8, 0),
                FlatStyle = FlatStyle.Flat, ForeColor = Color.White, BackColor = Color.FromArgb(62, 62, 68), TabStop = false, Cursor = Cursors.Hand,
                Font = new Font("Segoe UI", 9f, FontStyle.Bold),
            };
            b.FlatAppearance.BorderSize = 0;
            new ToolTip().SetToolTip(b, tip);
            return b;
        }

        static Control Separator()
        {
            return new Panel { Width = 1, Height = 26, Margin = new Padding(8, 3, 8, 0), BackColor = Color.FromArgb(70, 70, 76) };
        }

        void SelectTool(Tool t)
        {
            canvas.CurrentTool = t;
            UpdateToolButtons();
            canvas.Focus();
        }

        void UpdateToolButtons()
        {
            foreach (var kv in toolButtons)
            {
                var on = kv.Key == canvas.CurrentTool;
                kv.Value.BackColor = on ? Color.FromArgb(0x21, 0x55, 0xFF) : Color.Transparent;
            }
        }

        void UpdateSwatches()
        {
            for (var i = 0; i < swatches.Count; i++)
            {
                var on = Palette[i].ToArgb() == canvas.CurrentColor.ToArgb();
                swatches[i].FlatAppearance.BorderSize = on ? 3 : 1;
                swatches[i].FlatAppearance.BorderColor = on ? Color.White : Color.FromArgb(90, 90, 96);
            }
        }

        void UpdateToggles()
        {
            fillButton.BackColor = canvas.CurrentFilled ? Color.FromArgb(0x21, 0x55, 0xFF) : Color.Transparent;
        }

        void FitZoom()
        {
            var img = canvas.Image;
            var availW = Math.Max(200, scroller.ClientSize.Width - 40);
            var availH = Math.Max(150, scroller.ClientSize.Height - 40);
            var tall = (float)img.Height / img.Width > 1.8f;
            var z = tall ? Math.Min(1f, (float)availW / img.Width) : Math.Min(1f, Math.Min((float)availW / img.Width, (float)availH / img.Height));
            canvas.Zoom = Math.Max(0.05f, z);
            CenterCanvas();
        }

        void CenterCanvas()
        {
            var x = Math.Max(0, (scroller.ClientSize.Width - canvas.Width) / 2);
            var y = Math.Max(0, (scroller.ClientSize.Height - canvas.Height) / 2);
            canvas.Location = new Point(x - scroller.HorizontalScroll.Value, y - scroller.VerticalScroll.Value);
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            FitZoom();
            canvas.Focus();
            Activate();
        }

        protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
        {
            if (canvas.IsEditingText) return base.ProcessCmdKey(ref msg, keyData);
            switch (keyData)
            {
                case Keys.Control | Keys.Z: canvas.Undo(); return true;
                case Keys.Control | Keys.Y:
                case Keys.Control | Keys.Shift | Keys.Z: canvas.Redo(); return true;
                case Keys.Control | Keys.C: CopyResult(); return true;
                case Keys.Control | Keys.S: SaveResult(); return true;
                case Keys.Control | Keys.Shift | Keys.S: SaveAs(); return true;
                case Keys.Control | Keys.A: canvas.SelectAll(); return true;
                case Keys.Control | Keys.D: canvas.DuplicateSelection(); return true;
                case Keys.Control | Keys.D0: FitZoom(); return true;
                case Keys.Control | Keys.Oemplus: case Keys.Control | Keys.Add: canvas.Zoom *= 1.2f; CenterCanvas(); return true;
                case Keys.Control | Keys.OemMinus: case Keys.Control | Keys.Subtract: canvas.Zoom /= 1.2f; CenterCanvas(); return true;
            }
            return base.ProcessCmdKey(ref msg, keyData);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (canvas.IsEditingText) { base.OnKeyDown(e); return; }
            if (e.Modifiers == Keys.None || e.Modifiers == Keys.Shift)
            {
                foreach (var t in ToolInfo.Order)
                    if ((Keys)ToolInfo.Key(t) == e.KeyCode && e.Modifiers == Keys.None) { SelectTool(t); e.Handled = true; return; }
            }
            canvas.HandleKey(e);
            base.OnKeyDown(e);
        }

        void CopyResult()
        {
            using (var img = canvas.Render())
                ImageStore.CopyImage(img);
            Toast.Show("Copié dans le presse-papiers");
        }

        void SaveResult()
        {
            try
            {
                using (var img = canvas.Render()) ImageStore.SaveTo(img, filePath);
                Toast.Show("Enregistré");
                Close();
            }
            catch { Toast.Show("Échec de l'enregistrement"); }
        }

        void SaveAs()
        {
            using (var dlg = new SaveFileDialog
            {
                FileName = Path.GetFileNameWithoutExtension(filePath) + " annoté",
                Filter = "PNG|*.png|JPEG|*.jpg",
                InitialDirectory = Path.GetDirectoryName(filePath),
            })
            {
                if (dlg.ShowDialog(this) != DialogResult.OK) return;
                using (var img = canvas.Render()) ImageStore.SaveTo(img, dlg.FileName);
                Toast.Show("Enregistré : " + Path.GetFileName(dlg.FileName));
            }
        }
    }

    /// <summary>The drawing surface. Annotations live in image pixels; the control is the image scaled by Zoom.</summary>
    internal sealed class Canvas : Control
    {
        public Bitmap Image { get; private set; }
        readonly List<Annotation> items = new List<Annotation>();
        readonly Stack<Tuple<Bitmap, List<Annotation>>> undo = new Stack<Tuple<Bitmap, List<Annotation>>>();
        readonly Stack<Tuple<Bitmap, List<Annotation>>> redo = new Stack<Tuple<Bitmap, List<Annotation>>>();

        public event Action<bool> CropPendingChanged;
        public event Action<Tool> ToolChanged;
        public event Action ImageResized;

        Tool tool = Tool.Arrow;
        public Tool CurrentTool
        {
            get { return tool; }
            set { tool = value; if (value != Tool.Select) Deselect(); if (value != Tool.Crop) CancelCrop(); Cursor = value == Tool.Select ? Cursors.Default : Cursors.Cross; }
        }

        Color color = Color.FromArgb(255, 59, 48);
        public Color CurrentColor { get { return color; } set { color = value; ApplyToSelection(a => a.Color = value); } }

        float width = 4;
        public float CurrentWidth
        {
            get { return width; }
            set
            {
                width = value;
                ApplyToSelection(a =>
                {
                    a.Width = value;
                    if (a.Kind == Tool.Text) { a.FontSize = Annotation.FontFor(value); a.FitTextRect(); }
                });
            }
        }

        bool filled;
        public bool CurrentFilled
        {
            get { return filled; }
            set { filled = value; ApplyToSelection(a => { a.Filled = value; if (a.Kind == Tool.Text) a.FitTextRect(); }); }
        }

        float zoom = 1;
        public float Zoom
        {
            get { return zoom; }
            set { zoom = Math.Max(0.05f, Math.Min(8f, value)); Size = new Size(Math.Max(1, (int)(Image.Width * zoom)), Math.Max(1, (int)(Image.Height * zoom))); Invalidate(); }
        }

        Annotation active, moving, resizing, crop, editingText;
        int resizeHandle;
        PointF anchor, dragStart, lastPoint;
        TextBox textBox;
        public bool IsEditingText { get { return textBox != null; } }

        public Canvas(Bitmap image)
        {
            Image = image;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.Selectable, true);
            Zoom = 1;
        }

        PointF ToImage(Point p) { return new PointF(p.X / zoom, p.Y / zoom); }
        float Tolerance { get { return 8 / zoom; } }

        void ApplyToSelection(Action<Annotation> change)
        {
            var sel = items.Where(a => a.Selected).ToList();
            if (sel.Count == 0) return;
            PushUndo();
            foreach (var a in sel) change(a);
            Invalidate();
        }

        void Deselect() { foreach (var a in items) a.Selected = false; Invalidate(); }

        public void SelectAll() { foreach (var a in items) a.Selected = true; tool = Tool.Select; if (ToolChanged != null) ToolChanged(tool); Invalidate(); }

        // ---------- Painting ----------

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.InterpolationMode = zoom < 1 ? InterpolationMode.HighQualityBicubic : InterpolationMode.NearestNeighbor;
            g.PixelOffsetMode = PixelOffsetMode.Half;
            g.ScaleTransform(zoom, zoom);
            g.DrawImage(Image, 0, 0, Image.Width, Image.Height);
            g.PixelOffsetMode = PixelOffsetMode.Default;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            DrawLayers(g, true);
        }

        void DrawLayers(Graphics g, bool chrome)
        {
            var all = new List<Annotation>(items);
            if (active != null && chrome) all.Add(active);

            foreach (var a in all.Where(a => a.Kind == Tool.Blur || a.Kind == Tool.Pixelate)) a.Draw(g, Image);

            var spots = all.Where(a => a.Kind == Tool.Spotlight && a.Rect.Width > 1 && a.Rect.Height > 1).ToList();
            if (spots.Count > 0)
            {
                using (var region = new Region(new RectangleF(0, 0, Image.Width, Image.Height)))
                using (var dim = new SolidBrush(Color.FromArgb(140, 0, 0, 0)))
                {
                    foreach (var s in spots)
                        using (var path = SelectorForm.RoundedRect(s.Rect, Math.Min(12, Math.Min(s.Rect.Width, s.Rect.Height) / 2)))
                            region.Exclude(path);
                    g.FillRegion(dim, region);
                }
            }

            foreach (var a in all.Where(a => a.Kind != Tool.Blur && a.Kind != Tool.Pixelate && a.Kind != Tool.Spotlight && a.Kind != Tool.Crop))
                if (a != editingText) a.Draw(g, Image);

            if (!chrome) return;

            foreach (var a in all.Where(a => a.Selected)) DrawSelection(g, a);

            var c = crop ?? (active != null && active.Kind == Tool.Crop ? active : null);
            if (c != null) DrawCrop(g, c.Rect);
        }

        void DrawSelection(Graphics g, Annotation a)
        {
            var b = RectangleF.Inflate(a.Bounds, 6 / zoom, 6 / zoom);
            using (var pen = new Pen(Color.FromArgb(0x21, 0x55, 0xFF), 1.5f / zoom) { DashPattern = new float[] { 4, 3 } })
                g.DrawRectangle(pen, b.X, b.Y, b.Width, b.Height);
            var r = 5 / zoom;
            foreach (var h in a.Handles)
            {
                g.FillEllipse(Brushes.White, h.X - r, h.Y - r, r * 2, r * 2);
                using (var pen = new Pen(Color.FromArgb(0x21, 0x55, 0xFF), 1.5f / zoom)) g.DrawEllipse(pen, h.X - r, h.Y - r, r * 2, r * 2);
            }
        }

        void DrawCrop(Graphics g, RectangleF r)
        {
            using (var region = new Region(new RectangleF(0, 0, Image.Width, Image.Height)))
            using (var dim = new SolidBrush(Color.FromArgb(130, 0, 0, 0)))
            {
                region.Exclude(r);
                g.FillRegion(dim, region);
            }
            using (var pen = new Pen(Color.White, 1.5f / zoom)) g.DrawRectangle(pen, r.X, r.Y, r.Width, r.Height);
            using (var thin = new Pen(Color.FromArgb(100, 255, 255, 255), 1 / zoom))
            {
                for (var i = 1; i <= 2; i++)
                {
                    g.DrawLine(thin, r.X + r.Width * i / 3, r.Y, r.X + r.Width * i / 3, r.Bottom);
                    g.DrawLine(thin, r.X, r.Y + r.Height * i / 3, r.Right, r.Y + r.Height * i / 3);
                }
            }
            var label = (int)r.Width + " × " + (int)r.Height;
            using (var f = new Font("Segoe UI", 12 / zoom, FontStyle.Bold, GraphicsUnit.Pixel))
            {
                var s = g.MeasureString(label, f);
                var lr = new RectangleF(r.X, r.Bottom + 6 / zoom, s.Width + 10 / zoom, s.Height + 4 / zoom);
                using (var bg = new SolidBrush(Color.FromArgb(190, 0, 0, 0))) g.FillRectangle(bg, lr);
                g.DrawString(label, f, Brushes.White, lr.X + 5 / zoom, lr.Y + 2 / zoom);
            }
        }

        // ---------- Mouse ----------

        protected override void OnMouseDown(MouseEventArgs e)
        {
            Focus();
            CommitText();
            if (e.Button != MouseButtons.Left) return;
            var p = ToImage(e.Location);
            dragStart = p; lastPoint = p;

            var selected = items.LastOrDefault(a => a.Selected);
            if (selected != null)
            {
                var h = selected.HandleAt(p, 8 / zoom);
                if (h >= 0) { BeginResize(selected, h); return; }
            }

            if (tool == Tool.Select)
            {
                var hit = items.LastOrDefault(a => a.Hit(p, Tolerance));
                Deselect();
                if (hit != null)
                {
                    hit.Selected = true;
                    if (e.Clicks >= 2 && hit.Kind == Tool.Text) { EditText(hit); return; }
                    PushUndo();
                    moving = hit;
                }
                Invalidate();
                return;
            }

            Deselect();
            if (tool == Tool.Text) { StartText(p, null); return; }
            if (tool == Tool.Counter)
            {
                PushUndo();
                var n = items.Where(a => a.Kind == Tool.Counter).Select(a => a.Number).DefaultIfEmpty(0).Max() + 1;
                items.Add(new Annotation { Kind = Tool.Counter, Color = color, Width = width, Rect = new RectangleF(p, SizeF.Empty), Number = n });
                Invalidate();
                return;
            }
            if (tool == Tool.Crop)
            {
                crop = null;
                if (CropPendingChanged != null) CropPendingChanged(false);
                active = new Annotation { Kind = Tool.Crop, Rect = new RectangleF(p, SizeF.Empty) };
                return;
            }

            PushUndo();
            active = new Annotation { Kind = tool, Color = color, Width = width, Filled = filled };
            if (tool == Tool.Arrow || tool == Tool.Line) { active.Points.Add(p); active.Points.Add(p); }
            else if (tool == Tool.Pen) active.Points.Add(p);
            else active.Rect = new RectangleF(p, SizeF.Empty);
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            var p = ToImage(e.Location);
            var shift = (ModifierKeys & Keys.Shift) != 0;
            if (resizing != null) { ApplyResize(p, shift); Invalidate(); return; }
            if (moving != null && e.Button == MouseButtons.Left)
            {
                moving.Move(p.X - lastPoint.X, p.Y - lastPoint.Y);
                lastPoint = p;
                Invalidate();
                return;
            }
            if (active == null || e.Button != MouseButtons.Left) return;
            if (active.Kind == Tool.Arrow || active.Kind == Tool.Line) active.Points[1] = shift ? Snap45(active.Points[0], p) : p;
            else if (active.Kind == Tool.Pen) active.Points.Add(p);
            else { active.Rect = RectFrom(dragStart, p, shift); active.ClearEffect(); }
            Invalidate();
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            if (resizing != null) { resizing = null; return; }
            if (moving != null) { moving = null; return; }
            if (active == null) return;
            var a = active; active = null;

            if (a.Kind == Tool.Crop)
            {
                if (a.Rect.Width > 5 && a.Rect.Height > 5)
                {
                    crop = a;
                    if (CropPendingChanged != null) CropPendingChanged(true);
                }
                Invalidate();
                return;
            }

            bool tooSmall;
            if (a.Kind == Tool.Arrow || a.Kind == Tool.Line)
                tooSmall = Math.Abs(a.Points[1].X - a.Points[0].X) + Math.Abs(a.Points[1].Y - a.Points[0].Y) < 4;
            else if (a.Kind == Tool.Pen) tooSmall = a.Points.Count < 2;
            else tooSmall = a.Rect.Width < 3 || a.Rect.Height < 3;

            if (tooSmall) { if (undo.Count > 0) undo.Pop(); Invalidate(); return; }
            items.Add(a);
            redo.Clear();
            Invalidate();
        }

        protected override void OnMouseDoubleClick(MouseEventArgs e)
        {
            var p = ToImage(e.Location);
            var hit = items.LastOrDefault(a => a.Kind == Tool.Text && a.Hit(p, Tolerance));
            if (hit != null) EditText(hit);
        }

        protected override void OnMouseWheel(MouseEventArgs e)
        {
            if ((ModifierKeys & Keys.Control) != 0)
            {
                Zoom = Zoom * (e.Delta > 0 ? 1.15f : 1 / 1.15f);
                return;
            }
            base.OnMouseWheel(e);
        }

        static RectangleF RectFrom(PointF a, PointF b, bool square)
        {
            float w = Math.Abs(b.X - a.X), h = Math.Abs(b.Y - a.Y);
            if (square) { w = h = Math.Max(w, h); }
            var x = b.X >= a.X ? a.X : a.X - w;
            var y = b.Y >= a.Y ? a.Y : a.Y - h;
            return new RectangleF(x, y, w, h);
        }

        static PointF Snap45(PointF a, PointF b)
        {
            var ang = Math.Atan2(b.Y - a.Y, b.X - a.X);
            var len = Math.Sqrt((b.X - a.X) * (b.X - a.X) + (b.Y - a.Y) * (b.Y - a.Y));
            var snapped = Math.Round(ang / (Math.PI / 4)) * (Math.PI / 4);
            return new PointF(a.X + (float)(len * Math.Cos(snapped)), a.Y + (float)(len * Math.Sin(snapped)));
        }

        void BeginResize(Annotation a, int handle)
        {
            PushUndo();
            resizing = a; resizeHandle = handle;
            if (ToolInfo.IsRectBased(a.Kind))
            {
                var r = a.Rect;
                switch (handle)
                {
                    case 0: anchor = new PointF(r.Right, r.Bottom); break;
                    case 1: anchor = new PointF(r.Left, r.Bottom); break;
                    case 2: anchor = new PointF(r.Right, r.Top); break;
                    default: anchor = new PointF(r.Left, r.Top); break;
                }
            }
        }

        void ApplyResize(PointF p, bool shift)
        {
            var a = resizing;
            if (a.Kind == Tool.Arrow || a.Kind == Tool.Line)
            {
                var other = a.Points[resizeHandle == 0 ? 1 : 0];
                a.Points[resizeHandle] = shift ? Snap45(other, p) : p;
            }
            else { a.Rect = RectFrom(anchor, p, shift); a.ClearEffect(); }
        }

        // ---------- Keyboard ----------

        public void HandleKey(KeyEventArgs e)
        {
            switch (e.KeyCode)
            {
                case Keys.Escape:
                    if (crop != null) CancelCrop(); else Deselect();
                    e.Handled = true; break;
                case Keys.Enter:
                    if (crop != null) { ApplyCrop(); e.Handled = true; }
                    break;
                case Keys.Delete:
                case Keys.Back:
                    var sel = items.Where(a => a.Selected).ToList();
                    if (sel.Count > 0) { PushUndo(); foreach (var a in sel) items.Remove(a); Invalidate(); }
                    e.Handled = true; break;
                case Keys.Left: case Keys.Right: case Keys.Up: case Keys.Down:
                    var step = e.Shift ? 10f : 1f;
                    var moveSel = items.Where(a => a.Selected).ToList();
                    if (moveSel.Count == 0) break;
                    float dx = e.KeyCode == Keys.Left ? -step : e.KeyCode == Keys.Right ? step : 0;
                    float dy = e.KeyCode == Keys.Up ? -step : e.KeyCode == Keys.Down ? step : 0;
                    foreach (var a in moveSel) a.Move(dx, dy);
                    Invalidate(); e.Handled = true; break;
            }
        }

        protected override bool IsInputKey(Keys keyData)
        {
            var k = keyData & Keys.KeyCode;
            if (k == Keys.Left || k == Keys.Right || k == Keys.Up || k == Keys.Down) return true;
            return base.IsInputKey(keyData);
        }

        public void DuplicateSelection()
        {
            var sel = items.Where(a => a.Selected).ToList();
            if (sel.Count == 0) return;
            PushUndo();
            foreach (var a in sel)
            {
                a.Selected = false;
                var c = a.Clone();
                c.Move(14, 14);
                if (c.Kind == Tool.Counter) c.Number = items.Where(x => x.Kind == Tool.Counter).Select(x => x.Number).DefaultIfEmpty(0).Max() + 1;
                c.Selected = true;
                items.Add(c);
            }
            Invalidate();
        }

        // ---------- Text ----------

        void StartText(PointF at, Annotation existing)
        {
            var fontSize = existing != null ? existing.FontSize : Annotation.FontFor(width);
            textBox = new TextBox
            {
                BorderStyle = BorderStyle.None,
                Font = new Font("Segoe UI", Math.Max(6f, fontSize * zoom), FontStyle.Bold, GraphicsUnit.Pixel),
                ForeColor = existing != null && !existing.Filled ? existing.Color : (existing == null && !filled ? color : Color.Black),
                BackColor = Color.FromArgb(250, 250, 250),
                Text = existing != null ? existing.Text : "",
            };
            var origin = existing != null
                ? (existing.Filled ? new PointF(existing.Rect.X + Annotation.TextPad, existing.Rect.Y + Annotation.TextPad / 2) : existing.Rect.Location)
                : new PointF(at.X, at.Y - fontSize * 0.6f);
            textBox.Location = new Point((int)(origin.X * zoom), (int)(origin.Y * zoom));
            textBox.Width = Math.Max(200, (int)(Annotation.MeasureText(textBox.Text, fontSize).Width * zoom) + 60);
            textBox.Tag = Tuple.Create(origin, fontSize);
            textBox.KeyDown += (s, e) =>
            {
                if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; CommitText(); Focus(); }
                if (e.KeyCode == Keys.Escape) { e.SuppressKeyPress = true; CommitText(); Focus(); }
            };
            textBox.TextChanged += (s, e) =>
            {
                var t = (Tuple<PointF, float>)textBox.Tag;
                textBox.Width = Math.Max(200, (int)(Annotation.MeasureText(textBox.Text, t.Item2).Width * zoom) + 60);
            };
            textBox.LostFocus += (s, e) => CommitText();
            Controls.Add(textBox);
            textBox.Focus();
            textBox.SelectionStart = textBox.Text.Length;
        }

        void EditText(Annotation a)
        {
            PushUndo();
            items.Remove(a);
            editingText = a;
            StartText(a.Rect.Location, a);
            Invalidate();
        }

        void CommitText()
        {
            if (textBox == null) return;
            var tb = textBox; textBox = null;
            var info = (Tuple<PointF, float>)tb.Tag;
            var text = tb.Text;
            var template = editingText; editingText = null;
            Controls.Remove(tb);
            tb.Dispose();
            if (string.IsNullOrEmpty(text)) { Invalidate(); return; }
            if (template == null) PushUndo();
            var a = new Annotation
            {
                Kind = Tool.Text,
                Text = text,
                Color = template != null ? template.Color : color,
                Width = template != null ? template.Width : width,
                Filled = template != null ? template.Filled : filled,
                FontSize = info.Item2,
            };
            var origin = info.Item1;
            if (a.Filled) origin = new PointF(origin.X - Annotation.TextPad, origin.Y - Annotation.TextPad / 2);
            a.Rect = new RectangleF(origin, SizeF.Empty);
            a.FitTextRect();
            items.Add(a);
            redo.Clear();
            Invalidate();
        }

        // ---------- Crop ----------

        public void ApplyCrop()
        {
            if (crop == null) return;
            var r = Rectangle.Round(crop.Rect);
            r.Intersect(new Rectangle(0, 0, Image.Width, Image.Height));
            if (r.Width < 2 || r.Height < 2) { CancelCrop(); return; }
            PushUndo();
            var flattened = Render();
            var cropped = flattened.Clone(r, flattened.PixelFormat);
            flattened.Dispose();
            Image = cropped;
            items.Clear();
            crop = null;
            if (CropPendingChanged != null) CropPendingChanged(false);
            Zoom = zoom;
            if (ImageResized != null) ImageResized();
        }

        public void CancelCrop()
        {
            if (crop == null && (active == null || active.Kind != Tool.Crop)) return;
            crop = null;
            if (active != null && active.Kind == Tool.Crop) active = null;
            if (CropPendingChanged != null) CropPendingChanged(false);
            Invalidate();
        }

        // ---------- Undo ----------

        void PushUndo()
        {
            undo.Push(Tuple.Create(Image, items.Select(a => a.Clone()).ToList()));
            redo.Clear();
        }

        public void Undo()
        {
            CommitText();
            if (undo.Count == 0) return;
            redo.Push(Tuple.Create(Image, items.Select(a => a.Clone()).ToList()));
            Restore(undo.Pop());
        }

        public void Redo()
        {
            if (redo.Count == 0) return;
            undo.Push(Tuple.Create(Image, items.Select(a => a.Clone()).ToList()));
            Restore(redo.Pop());
        }

        void Restore(Tuple<Bitmap, List<Annotation>> state)
        {
            var resized = state.Item1 != Image;
            Image = state.Item1;
            items.Clear();
            items.AddRange(state.Item2);
            crop = null; moving = null; resizing = null;
            if (CropPendingChanged != null) CropPendingChanged(false);
            if (resized) { Zoom = zoom; if (ImageResized != null) ImageResized(); }
            Invalidate();
        }

        // ---------- Export ----------

        /// <summary>Image with every annotation burned in, at full resolution.</summary>
        public Bitmap Render()
        {
            CommitText();
            var result = new Bitmap(Image.Width, Image.Height, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(result))
            {
                g.DrawImage(Image, 0, 0, Image.Width, Image.Height);
                g.SmoothingMode = SmoothingMode.AntiAlias;
                DrawLayers(g, false);
            }
            return result;
        }
    }
}
