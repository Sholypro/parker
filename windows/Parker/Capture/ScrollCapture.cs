using System;
using System.Drawing;
using System.Collections.Generic;
using System.Drawing.Drawing2D;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace Parker
{
    /// <summary>
    /// Scrolling capture: select an area, then scroll yourself (frames captured ~22/s and stitched
    /// live) or press Auto and Parker scrolls to the end of the page. Live preview on the side.
    /// The HUD, border and preview are excluded from capture (WDA_EXCLUDEFROMCAPTURE).
    /// </summary>
    internal sealed class ScrollCapture
    {
        readonly Action<string> onDone;
        Rectangle area;
        ScrollStitcher stitcher;
        readonly object stitchLock = new object();
        FrameBuffer buffer;
        SynchronizationContext ui;
        System.Windows.Forms.Timer keyTimer;
        volatile bool active, auto;
        int autoUnchanged, autoNoMatch, autoStep;
        HudForm hud;
        BorderForm border;
        PreviewForm preview;
        string lastStatus;
        bool lastWarning;
        const int MaxHeight = 40000;
        const int FrameIntervalMs = 45;   // ~22 frames per second
        const int PreviewIntervalMs = 250;

        public ScrollCapture(Action<string> onDone) { this.onDone = onDone; }

        public void Start()
        {
            Selector.Show(SelectMode.Area, (rect, snapshot) =>
            {
                if (snapshot != null) snapshot.Dispose();
                if (!rect.HasValue || rect.Value.Width < 40 || rect.Value.Height < 60) return;
                area = rect.Value;
                Begin();
            });
        }

        void Begin()
        {
            ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
            stitcher = new ScrollStitcher();
            buffer = new FrameBuffer((long)area.Width * area.Height * 4);
            active = true;
            border = new BorderForm(area);
            border.Show();
            hud = new HudForm(area);
            hud.AutoClicked += ToggleAuto;
            hud.DoneClicked += Finish;
            hud.CancelClicked += Cancel;
            hud.Show();
            preview = new PreviewForm(area);
            preview.Show();
            SetStatus("Fais défiler, ou lance l'auto-scroll", false);

            // Esc works even when another app has the focus
            keyTimer = new System.Windows.Forms.Timer { Interval = 80 };
            keyTimer.Tick += (s, e) => { if ((Native.GetAsyncKeyState(0x1B) & 0x8000) != 0) Cancel(); };
            keyTimer.Start();

            // Capture continuously on one thread, stitch on another: a slow stitch never makes
            // the capture miss the frames in between (they are kept and used to bridge the gap).
            new Thread(CaptureLoop) { IsBackground = true, Name = "Parker scroll capture" }.Start();
            new Thread(StitchLoop) { IsBackground = true, Name = "Parker scroll stitch" }.Start();
        }

        void CaptureLoop()
        {
            var watch = System.Diagnostics.Stopwatch.StartNew();
            while (active)
            {
                var t0 = watch.ElapsedMilliseconds;
                if (!auto)
                {
                    var frame = Grab();
                    if (frame != null) buffer.Push(frame);
                }
                var wait = FrameIntervalMs - (int)(watch.ElapsedMilliseconds - t0);
                Thread.Sleep(Math.Max(5, wait));
            }
        }

        Bitmap Grab()
        {
            try { return ScreenGrab.Capture(area); }
            catch { return null; }   // e.g. secure desktop (UAC prompt, lock screen)
        }

        void StitchLoop()
        {
            var lastPreview = DateTime.MinValue;
            while (active)
            {
                if (auto || buffer.Count == 0) { Thread.Sleep(10); continue; }
                ScrollStitcher.Result result;
                Bitmap thumb = null;
                int height;
                lock (stitchLock)
                {
                    if (!active || auto) continue;
                    result = stitcher.AddBatch(buffer.Drain(), null);
                    height = stitcher.TotalHeight;
                    var grew = result == ScrollStitcher.Result.First || result == ScrollStitcher.Result.Appended;
                    if (grew && (DateTime.Now - lastPreview).TotalMilliseconds >= PreviewIntervalMs)
                    {
                        thumb = stitcher.Compose(260);
                        lastPreview = DateTime.Now;
                    }
                }
                var r = result; var th = thumb; var hgt = height;
                ui.Post(_ => Handle(r, th, hgt), null);
            }
        }

        void Handle(ScrollStitcher.Result result, Bitmap thumb, int height)
        {
            if (!active) { if (thumb != null) thumb.Dispose(); return; }
            if (thumb != null) preview.SetImage(thumb);
            preview.SetHeight(height);
            switch (result)
            {
                case ScrollStitcher.Result.NoMatch:
                    if (!auto) SetStatus("Trop rapide : remonte un peu, la capture reprendra toute seule", true);
                    break;
                case ScrollStitcher.Result.Repositioned:
                    if (!auto) SetStatus("Zone déjà capturée : redescends pour continuer", false);
                    break;
                case ScrollStitcher.Result.Appended:
                    SetStatus(auto ? "Auto-scroll en cours…" : (lastWarning ? "C'est reparti, continue de défiler" : "Capture en cours, continue de défiler"), false);
                    break;
            }
            if (height >= MaxHeight) Finish();
        }

        void SetStatus(string text, bool warning)
        {
            if (hud == null) return;
            if (text == lastStatus && warning == lastWarning) return;
            lastStatus = text; lastWarning = warning;
            hud.SetStatus(text, warning);
        }

        void ToggleAuto()
        {
            if (!active) return;
            if (auto)
            {
                auto = false;
                hud.SetAuto(false);
                SetStatus("Auto-scroll en pause", false);
                return;
            }
            auto = true;
            autoUnchanged = 0; autoNoMatch = 0;
            hud.SetAuto(true);
            SetStatus("Auto-scroll en cours…", false);
            // Cursor over the content so the wheel events reach the right window
            Native.SetCursorPos(area.X + area.Width / 2, area.Y + area.Height / 2);
            AutoStep();
        }

        void AutoStep()
        {
            if (!active || !auto) return;
            // 120 = one wheel notch (≈ 3 lines). Scroll ~ a third of the area per step.
            autoStep = Math.Max(1, Math.Min(6, area.Height / 300)) * 120;
            Native.SetCursorPos(area.X + area.Width / 2, area.Y + area.Height / 2);
            Native.ScrollWheel(-autoStep);
            var wait = new System.Windows.Forms.Timer { Interval = 320 };
            wait.Tick += (s, e) =>
            {
                wait.Stop(); wait.Dispose();
                if (!active || !auto) return;
                int? expected;
                lock (stitchLock) expected = stitcher.LastDelta > 0 ? (int?)stitcher.LastDelta : null;
                Task.Run(() =>
                {
                    var frame = Grab();
                    lock (stitchLock)
                    {
                        var frames = buffer.Drain();
                        if (frame != null) frames.Add(frame);
                        if (!active) { foreach (var f in frames) f.Dispose(); return Tuple.Create(ScrollStitcher.Result.NoMatch, (Bitmap)null, 0); }
                        var res = stitcher.AddBatch(frames, expected);
                        Bitmap thumb = null;
                        if (res == ScrollStitcher.Result.First || res == ScrollStitcher.Result.Appended) thumb = stitcher.Compose(260);
                        return Tuple.Create(res, thumb, stitcher.TotalHeight);
                    }
                }).ContinueWith(t =>
                {
                    var r = t.Result;
                    Handle(r.Item1, r.Item2, r.Item3);
                    if (!active || !auto) return;
                    if (r.Item1 == ScrollStitcher.Result.Unchanged) { autoUnchanged++; autoNoMatch = 0; }
                    else if (r.Item1 == ScrollStitcher.Result.NoMatch) autoNoMatch++;
                    else { autoUnchanged = 0; autoNoMatch = 0; }

                    if (autoUnchanged >= 2) Finish();            // nothing moves: end of page
                    else if (autoNoMatch >= 3)
                    {
                        auto = false; hud.SetAuto(false);
                        SetStatus("Auto-scroll arrêté : contenu impossible à raccorder", true);
                    }
                    else AutoStep();
                }, TaskScheduler.FromCurrentSynchronizationContext());
            };
            wait.Start();
        }

        void Finish()
        {
            if (!active) return;
            active = false; auto = false;
            Teardown();
            var st = stitcher;
            var buf = buffer;
            Task.Run(() =>
            {
                Thread.Sleep(60); // let the HUD disappear before the last frame
                var last = Grab();
                lock (stitchLock)
                {
                    var frames = buf.Drain();
                    if (last != null) frames.Add(last);
                    st.AddBatch(frames, null);
                    var image = st.Compose();
                    st.Dispose();
                    return image;
                }
            }).ContinueWith(t =>
            {
                var image = t.Result;
                if (image == null) { onDone(null); return; }
                var path = ImageStore.Finish(image);
                image.Dispose();
                onDone(path);
            }, TaskScheduler.FromCurrentSynchronizationContext());
        }

        void Cancel()
        {
            if (!active) return;
            active = false; auto = false;
            Teardown();
            var st = stitcher;
            var buf = buffer;
            Task.Run(() =>
            {
                lock (stitchLock)
                {
                    foreach (var f in buf.Drain()) f.Dispose();
                    st.Dispose();
                }
            });
        }

        void Teardown()
        {
            if (keyTimer != null) { keyTimer.Stop(); keyTimer.Dispose(); keyTimer = null; }
            if (hud != null) { hud.Close(); hud = null; }
            if (border != null) { border.Close(); border = null; }
            if (preview != null) { preview.Close(); preview = null; }
        }

        /// <summary>
        /// Frames waiting to be stitched. When the stitcher falls behind, every other frame is
        /// dropped (newest always kept) so memory stays bounded while gaps stay small.
        /// </summary>
        sealed class FrameBuffer
        {
            readonly List<Bitmap> frames = new List<Bitmap>();
            readonly int max;

            public FrameBuffer(long frameBytes)
            {
                max = (int)Math.Max(3, Math.Min(16, 240L * 1024 * 1024 / Math.Max(1, frameBytes)));
            }

            public int Count { get { lock (frames) return frames.Count; } }

            public void Push(Bitmap frame)
            {
                lock (frames)
                {
                    frames.Add(frame);
                    if (frames.Count > max)
                    {
                        for (var i = frames.Count - 2; i >= 1; i -= 2)
                        {
                            frames[i].Dispose();
                            frames.RemoveAt(i);
                        }
                    }
                }
            }

            public List<Bitmap> Drain()
            {
                lock (frames)
                {
                    var list = new List<Bitmap>(frames);
                    frames.Clear();
                    return list;
                }
            }
        }

        // ---------- Windows ----------

        /// <summary>Base for small always-on-top windows that never steal focus and are invisible to captures.</summary>
        internal class FloatingForm : Form
        {
            public FloatingForm()
            {
                FormBorderStyle = FormBorderStyle.None;
                ShowInTaskbar = false;
                StartPosition = FormStartPosition.Manual;
                AutoScaleMode = AutoScaleMode.None;
                TopMost = true;
                SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint, true);
            }

            protected override bool ShowWithoutActivation { get { return true; } }

            protected override CreateParams CreateParams
            {
                get
                {
                    var cp = base.CreateParams;
                    cp.ExStyle |= Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOPMOST;
                    return cp;
                }
            }

            protected override void OnHandleCreated(EventArgs e)
            {
                base.OnHandleCreated(e);
                Native.ExcludeFromCapture(Handle);
            }

        }

        sealed class BorderForm : FloatingForm
        {
            public BorderForm(Rectangle area)
            {
                var r = Rectangle.Inflate(area, 4, 4);
                Bounds = r;
                BackColor = Color.Magenta;
                TransparencyKey = Color.Magenta;
            }

            protected override CreateParams CreateParams
            {
                get
                {
                    var cp = base.CreateParams;
                    cp.ExStyle |= Native.WS_EX_TRANSPARENT | Native.WS_EX_LAYERED; // click-through
                    return cp;
                }
            }

            protected override void OnPaint(PaintEventArgs e)
            {
                e.Graphics.Clear(Color.Magenta);
                using (var pen = new Pen(Color.FromArgb(0x21, 0x55, 0xFF), 2) { DashPattern = new float[] { 4, 3 } })
                    e.Graphics.DrawRectangle(pen, 1, 1, Width - 3, Height - 3);
            }
        }

        sealed class HudForm : FloatingForm
        {
            public event Action AutoClicked, DoneClicked, CancelClicked;
            readonly Label status;
            readonly Button autoBtn, doneBtn, cancelBtn;

            public HudForm(Rectangle area)
            {
                BackColor = Color.FromArgb(32, 32, 36);
                var s = Dpi.ForRect(area);
                var w = (int)(460 * s); var h = (int)(52 * s);
                var screen = Screen.FromRectangle(area).WorkingArea;
                var x = area.X + area.Width / 2 - w / 2;
                var y = area.Bottom + (int)(12 * s);
                if (y + h > screen.Bottom) y = area.Y - h - (int)(12 * s);
                if (y < screen.Top) y = area.Bottom - h - (int)(24 * s);
                x = Math.Max(screen.Left + 8, Math.Min(x, screen.Right - w - 8));
                Bounds = new Rectangle(x, y, w, h);
                Region = new Region(SelectorForm.RoundedRect(new RectangleF(0, 0, w, h), 12 * s));

                cancelBtn = MakeButton("✕", (int)(36 * s));
                doneBtn = MakeButton("Terminer", (int)(96 * s));
                doneBtn.BackColor = Color.FromArgb(0x21, 0x55, 0xFF);
                autoBtn = MakeButton("▶ Auto", (int)(80 * s));
                status = new Label
                {
                    ForeColor = Color.White,
                    Font = new Font("Segoe UI", 9f),
                    AutoSize = false,
                    TextAlign = ContentAlignment.MiddleLeft,
                };
                var pad = (int)(10 * s); var bh = (int)(32 * s); var by = (h - bh) / 2;
                cancelBtn.SetBounds(w - pad - cancelBtn.Width, by, cancelBtn.Width, bh);
                doneBtn.SetBounds(cancelBtn.Left - 6 - doneBtn.Width, by, doneBtn.Width, bh);
                autoBtn.SetBounds(doneBtn.Left - 6 - autoBtn.Width, by, autoBtn.Width, bh);
                status.SetBounds(pad + 4, 0, autoBtn.Left - pad - 8, h);
                Controls.AddRange(new Control[] { status, autoBtn, doneBtn, cancelBtn });
                autoBtn.Click += (o, e) => { if (AutoClicked != null) AutoClicked(); };
                doneBtn.Click += (o, e) => { if (DoneClicked != null) DoneClicked(); };
                cancelBtn.Click += (o, e) => { if (CancelClicked != null) CancelClicked(); };
            }

            Button MakeButton(string text, int width)
            {
                var b = new Button
                {
                    Text = text,
                    Width = width,
                    FlatStyle = FlatStyle.Flat,
                    ForeColor = Color.White,
                    BackColor = Color.FromArgb(58, 58, 64),
                    Font = new Font("Segoe UI", 9f, FontStyle.Bold),
                    Cursor = Cursors.Hand,
                    TabStop = false,
                };
                b.FlatAppearance.BorderSize = 0;
                return b;
            }

            public void SetStatus(string text, bool warning)
            {
                status.Text = text;
                status.ForeColor = warning ? Color.FromArgb(255, 170, 60) : Color.White;
            }

            public void SetAuto(bool on) { autoBtn.Text = on ? "❚❚ Pause" : "▶ Auto"; }
        }

        sealed class PreviewForm : FloatingForm
        {
            Bitmap image;
            int height;
            readonly float scale;

            public PreviewForm(Rectangle area)
            {
                BackColor = Color.FromArgb(24, 24, 28);
                var s = Dpi.ForRect(area);
                scale = s;
                var w = (int)(170 * s);
                var h = Math.Min(Math.Max(area.Height, (int)(200 * s)), (int)(440 * s));
                var screen = Screen.FromRectangle(area).WorkingArea;
                int x;
                if (screen.Right - area.Right >= w + 22) x = area.Right + 14;
                else if (area.Left - screen.Left >= w + 22) x = area.Left - w - 14;
                else x = area.Right - w - 16;
                var y = Math.Max(screen.Top + 8, Math.Min(area.Top, screen.Bottom - h - 8));
                Bounds = new Rectangle(x, y, w, h);
                Region = new Region(SelectorForm.RoundedRect(new RectangleF(0, 0, w, h), 10 * s));
            }

            protected override CreateParams CreateParams
            {
                get
                {
                    var cp = base.CreateParams;
                    cp.ExStyle |= Native.WS_EX_TRANSPARENT | Native.WS_EX_LAYERED;
                    return cp;
                }
            }

            protected override void OnHandleCreated(EventArgs e)
            {
                base.OnHandleCreated(e);
                // Layered windows need an alpha to be drawn; fully opaque
                Opacity = 0.97;
            }

            public void SetImage(Bitmap bmp)
            {
                if (image != null) image.Dispose();
                image = bmp;
                Invalidate();
            }

            public void SetHeight(int h) { height = h; Invalidate(); }

            protected override void OnPaint(PaintEventArgs e)
            {
                var g = e.Graphics;
                g.Clear(BackColor);
                var s = scale;
                var inset = (int)(8 * s); var labelH = (int)(22 * s);
                var areaRect = new Rectangle(inset, inset + labelH, Width - inset * 2, Height - inset * 2 - labelH);
                if (image != null)
                {
                    var sc = (float)areaRect.Width / image.Width;
                    var drawH = image.Height * sc;
                    var y = drawH <= areaRect.Height ? areaRect.Top : areaRect.Bottom - drawH;
                    g.SetClip(areaRect);
                    g.InterpolationMode = InterpolationMode.HighQualityBilinear;
                    g.DrawImage(image, areaRect.Left, y, areaRect.Width, drawH);
                    g.ResetClip();
                }
                using (var f = new Font("Segoe UI", 8.5f, FontStyle.Bold))
                    g.DrawString(height + " px", f, Brushes.White, inset, inset);
            }

            protected override void Dispose(bool disposing)
            {
                if (disposing && image != null) image.Dispose();
                base.Dispose(disposing);
            }
        }
    }
}
