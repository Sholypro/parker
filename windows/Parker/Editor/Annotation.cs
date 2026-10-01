using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Linq;

namespace Parker
{
    internal enum Tool { Select, Arrow, Rectangle, Ellipse, Line, Text, Pen, Highlight, Counter, Blur, Pixelate, Spotlight, Crop }

    internal static class ToolInfo
    {
        public static readonly Tool[] Order =
        {
            Tool.Select, Tool.Arrow, Tool.Rectangle, Tool.Ellipse, Tool.Line, Tool.Text, Tool.Pen,
            Tool.Highlight, Tool.Counter, Tool.Blur, Tool.Pixelate, Tool.Spotlight, Tool.Crop
        };

        public static string Label(Tool t)
        {
            switch (t)
            {
                case Tool.Select: return "Sélection";
                case Tool.Arrow: return "Flèche";
                case Tool.Rectangle: return "Rectangle";
                case Tool.Ellipse: return "Ellipse";
                case Tool.Line: return "Ligne";
                case Tool.Text: return "Texte";
                case Tool.Pen: return "Crayon";
                case Tool.Highlight: return "Surligneur";
                case Tool.Counter: return "Compteur";
                case Tool.Blur: return "Flou";
                case Tool.Pixelate: return "Pixellisation";
                case Tool.Spotlight: return "Spotlight";
                default: return "Recadrer";
            }
        }

        public static char Key(Tool t)
        {
            switch (t)
            {
                case Tool.Select: return 'V';
                case Tool.Arrow: return 'A';
                case Tool.Rectangle: return 'R';
                case Tool.Ellipse: return 'O';
                case Tool.Line: return 'L';
                case Tool.Text: return 'T';
                case Tool.Pen: return 'P';
                case Tool.Highlight: return 'H';
                case Tool.Counter: return 'N';
                case Tool.Blur: return 'B';
                case Tool.Pixelate: return 'X';
                case Tool.Spotlight: return 'S';
                default: return 'C';
            }
        }

        /// <summary>Segoe Fluent / MDL2 glyphs (both fonts share these code points).</summary>
        public static string Glyph(Tool t)
        {
            switch (t)
            {
                case Tool.Select: return "";
                case Tool.Arrow: return "";
                case Tool.Rectangle: return "";
                case Tool.Ellipse: return "";
                case Tool.Line: return "";
                case Tool.Text: return "";
                case Tool.Pen: return "";
                case Tool.Highlight: return "";
                case Tool.Counter: return "";
                case Tool.Blur: return "";
                case Tool.Pixelate: return "";
                case Tool.Spotlight: return "";
                default: return "";
            }
        }

        public static bool IsRectBased(Tool t)
        {
            return t == Tool.Rectangle || t == Tool.Ellipse || t == Tool.Highlight || t == Tool.Blur || t == Tool.Pixelate || t == Tool.Spotlight;
        }
    }

    /// <summary>One annotation, in image pixel coordinates.</summary>
    internal sealed class Annotation
    {
        public Tool Kind;
        public Color Color;
        public float Width;
        public bool Filled;
        public List<PointF> Points = new List<PointF>();
        public RectangleF Rect;
        public string Text = "";
        public float FontSize = 28;
        public int Number = 1;
        public bool Selected;

        // Cache for blur/pixelate
        public Bitmap Effect;
        public RectangleF EffectRect;

        public Annotation Clone()
        {
            return new Annotation
            {
                Kind = Kind, Color = Color, Width = Width, Filled = Filled,
                Points = new List<PointF>(Points), Rect = Rect, Text = Text, FontSize = FontSize, Number = Number,
            };
        }

        public static float FontFor(float width) { return 14 + width * 3.2f; }
        public float CounterDiameter { get { return 26 + Width * 4; } }
        public RectangleF CounterRect { get { var d = CounterDiameter; return new RectangleF(Rect.X - d / 2, Rect.Y - d / 2, d, d); } }

        public RectangleF Bounds
        {
            get
            {
                if (Kind == Tool.Arrow || Kind == Tool.Line || Kind == Tool.Pen)
                {
                    if (Points.Count == 0) return RectangleF.Empty;
                    float x0 = Points.Min(p => p.X), y0 = Points.Min(p => p.Y), x1 = Points.Max(p => p.X), y1 = Points.Max(p => p.Y);
                    return RectangleF.FromLTRB(x0, y0, x1, y1);
                }
                if (Kind == Tool.Counter) return CounterRect;
                return Rect;
            }
        }

        public PointF[] Handles
        {
            get
            {
                if ((Kind == Tool.Arrow || Kind == Tool.Line) && Points.Count >= 2) return new[] { Points[0], Points[1] };
                if (ToolInfo.IsRectBased(Kind))
                    return new[] { new PointF(Rect.Left, Rect.Top), new PointF(Rect.Right, Rect.Top), new PointF(Rect.Left, Rect.Bottom), new PointF(Rect.Right, Rect.Bottom) };
                return new PointF[0];
            }
        }

        public void Move(float dx, float dy)
        {
            for (var i = 0; i < Points.Count; i++) Points[i] = new PointF(Points[i].X + dx, Points[i].Y + dy);
            Rect.Offset(dx, dy);
            ClearEffect();
        }

        public void ClearEffect()
        {
            if (Effect != null) { Effect.Dispose(); Effect = null; }
        }

        static Color Contrast(Color c)
        {
            var lum = 0.299 * c.R + 0.587 * c.G + 0.114 * c.B;
            return lum > 165 ? Color.Black : Color.White;
        }

        // ---------- Drawing (image coordinates) ----------

        public void Draw(Graphics g, Bitmap baseImage)
        {
            switch (Kind)
            {
                case Tool.Arrow: DrawArrow(g); break;
                case Tool.Rectangle: DrawRect(g); break;
                case Tool.Ellipse: DrawEllipse(g); break;
                case Tool.Line: DrawLine(g); break;
                case Tool.Text: DrawText(g); break;
                case Tool.Pen: DrawPen(g); break;
                case Tool.Highlight: DrawHighlight(g); break;
                case Tool.Counter: DrawCounter(g); break;
                case Tool.Blur:
                case Tool.Pixelate: DrawEffect(g, baseImage); break;
            }
        }

        void DrawArrow(Graphics g)
        {
            if (Points.Count < 2) return;
            var s = Points[0]; var e = Points[1];
            var len = Math.Sqrt((e.X - s.X) * (e.X - s.X) + (e.Y - s.Y) * (e.Y - s.Y));
            if (len < 2) return;
            var a = Math.Atan2(e.Y - s.Y, e.X - s.X);
            var head = (float)Math.Min(Math.Max(18, Width * 5), len * 0.6);
            var ha = Math.PI / 7;
            var p1 = new PointF(e.X - head * (float)Math.Cos(a - ha), e.Y - head * (float)Math.Sin(a - ha));
            var p2 = new PointF(e.X - head * (float)Math.Cos(a + ha), e.Y - head * (float)Math.Sin(a + ha));
            var b = new PointF((p1.X + p2.X) / 2, (p1.Y + p2.Y) / 2);
            var perp = a + Math.PI / 2;
            float tail = Math.Max(1, Width * 0.25f), w = Width * 0.75f;
            var shaft = new[]
            {
                new PointF(s.X + tail * (float)Math.Cos(perp), s.Y + tail * (float)Math.Sin(perp)),
                new PointF(b.X + w * (float)Math.Cos(perp), b.Y + w * (float)Math.Sin(perp)),
                new PointF(b.X - w * (float)Math.Cos(perp), b.Y - w * (float)Math.Sin(perp)),
                new PointF(s.X - tail * (float)Math.Cos(perp), s.Y - tail * (float)Math.Sin(perp)),
            };
            using (var br = new SolidBrush(Color))
            using (var pen = new Pen(Color, Math.Max(1, Width * 0.5f)) { LineJoin = LineJoin.Round })
            {
                g.FillPolygon(br, shaft);
                var tri = new[] { e, p1, p2 };
                g.FillPolygon(br, tri);
                g.DrawPolygon(pen, tri);
            }
        }

        void DrawRect(Graphics g)
        {
            var radius = Math.Min(6, Math.Min(Rect.Width, Rect.Height) / 2);
            using (var path = SelectorForm.RoundedRect(Rect, radius))
            {
                if (Filled) using (var br = new SolidBrush(Color.FromArgb(77, Color))) g.FillPath(br, path);
                using (var pen = new Pen(Color, Width) { LineJoin = LineJoin.Round }) g.DrawPath(pen, path);
            }
        }

        void DrawEllipse(Graphics g)
        {
            if (Filled) using (var br = new SolidBrush(Color.FromArgb(77, Color))) g.FillEllipse(br, Rect);
            using (var pen = new Pen(Color, Width)) g.DrawEllipse(pen, Rect);
        }

        void DrawLine(Graphics g)
        {
            if (Points.Count < 2) return;
            using (var pen = new Pen(Color, Width) { StartCap = LineCap.Round, EndCap = LineCap.Round }) g.DrawLine(pen, Points[0], Points[1]);
        }

        void DrawPen(Graphics g)
        {
            if (Points.Count < 2) return;
            using (var pen = new Pen(Color, Width) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
            {
                if (Points.Count < 4) g.DrawLines(pen, Points.ToArray());
                else g.DrawCurve(pen, Points.ToArray(), 0.5f);
            }
        }

        void DrawHighlight(Graphics g)
        {
            using (var br = new SolidBrush(Color.FromArgb(100, Color))) g.FillRectangle(br, Rect);
        }

        void DrawCounter(Graphics g)
        {
            var r = CounterRect;
            using (var shadow = new SolidBrush(Color.FromArgb(70, 0, 0, 0))) g.FillEllipse(shadow, r.X, r.Y + 2, r.Width, r.Height);
            using (var br = new SolidBrush(Color)) g.FillEllipse(br, r);
            using (var pen = new Pen(Color.White, Math.Max(2, r.Width * 0.07f))) g.DrawEllipse(pen, RectangleF.Inflate(r, -1, -1));
            using (var f = new Font("Segoe UI", r.Height * 0.48f, FontStyle.Bold, GraphicsUnit.Pixel))
            using (var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
            using (var tb = new SolidBrush(Contrast(Color)))
                g.DrawString(Number.ToString(), f, tb, r, sf);
        }

        public const float TextPad = 10;

        public static SizeF MeasureText(string text, float fontSize)
        {
            using (var bmp = new Bitmap(1, 1))
            using (var g = Graphics.FromImage(bmp))
            using (var f = new Font("Segoe UI", fontSize, FontStyle.Bold, GraphicsUnit.Pixel))
            {
                var s = g.MeasureString(string.IsNullOrEmpty(text) ? " " : text, f, PointF.Empty, StringFormat.GenericTypographic);
                return new SizeF(s.Width + 2, f.GetHeight(g));
            }
        }

        public void FitTextRect()
        {
            var s = MeasureText(Text, FontSize);
            Rect = Filled
                ? new RectangleF(Rect.X, Rect.Y, s.Width + TextPad * 2, s.Height + TextPad)
                : new RectangleF(Rect.X, Rect.Y, s.Width, s.Height);
        }

        void DrawText(Graphics g)
        {
            using (var f = new Font("Segoe UI", FontSize, FontStyle.Bold, GraphicsUnit.Pixel))
            {
                g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                if (Filled)
                {
                    using (var path = SelectorForm.RoundedRect(Rect, 8))
                    using (var br = new SolidBrush(Color)) g.FillPath(br, path);
                    using (var tb = new SolidBrush(Contrast(Color)))
                        g.DrawString(Text, f, tb, Rect.X + TextPad, Rect.Y + TextPad / 2, StringFormat.GenericTypographic);
                }
                else
                {
                    using (var sh = new SolidBrush(Color.FromArgb(90, 0, 0, 0)))
                        g.DrawString(Text, f, sh, Rect.X + 1, Rect.Y + 2, StringFormat.GenericTypographic);
                    using (var tb = new SolidBrush(Color)) g.DrawString(Text, f, tb, Rect.X, Rect.Y, StringFormat.GenericTypographic);
                }
            }
        }

        void DrawEffect(Graphics g, Bitmap baseImage)
        {
            var r = Rectangle.Round(Rect);
            r.Intersect(new Rectangle(0, 0, baseImage.Width, baseImage.Height));
            if (r.Width < 2 || r.Height < 2) return;
            if (Effect == null || EffectRect != Rect)
            {
                ClearEffect();
                Effect = Kind == Tool.Blur ? Blur(baseImage, r) : Pixelate(baseImage, r);
                EffectRect = Rect;
            }
            g.DrawImageUnscaled(Effect, r.X, r.Y);
        }

        static Bitmap Blur(Bitmap src, Rectangle r)
        {
            // Down/up-sample twice: cheap and close to a gaussian blur
            var factor = Math.Max(6, Math.Min(r.Width, r.Height) / 10);
            var sw = Math.Max(1, r.Width / factor); var sh = Math.Max(1, r.Height / factor);
            using (var small = new Bitmap(sw, sh))
            {
                using (var g = Graphics.FromImage(small))
                {
                    g.InterpolationMode = InterpolationMode.HighQualityBilinear;
                    g.DrawImage(src, new Rectangle(0, 0, sw, sh), r, GraphicsUnit.Pixel);
                }
                var outBmp = new Bitmap(r.Width, r.Height);
                using (var g = Graphics.FromImage(outBmp))
                using (var attrs = new ImageAttributes())
                {
                    attrs.SetWrapMode(WrapMode.TileFlipXY);
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    g.DrawImage(small, new Rectangle(0, 0, r.Width, r.Height), 0, 0, sw, sh, GraphicsUnit.Pixel, attrs);
                }
                return outBmp;
            }
        }

        static Bitmap Pixelate(Bitmap src, Rectangle r)
        {
            var block = Math.Max(8, Math.Max(r.Width, r.Height) / 14);
            var sw = Math.Max(1, r.Width / block); var sh = Math.Max(1, r.Height / block);
            using (var small = new Bitmap(sw, sh))
            {
                using (var g = Graphics.FromImage(small))
                {
                    g.InterpolationMode = InterpolationMode.HighQualityBilinear;
                    g.DrawImage(src, new Rectangle(0, 0, sw, sh), r, GraphicsUnit.Pixel);
                }
                var outBmp = new Bitmap(r.Width, r.Height);
                using (var g = Graphics.FromImage(outBmp))
                {
                    g.InterpolationMode = InterpolationMode.NearestNeighbor;
                    g.PixelOffsetMode = PixelOffsetMode.Half;
                    g.DrawImage(small, new Rectangle(0, 0, r.Width, r.Height), new Rectangle(0, 0, sw, sh), GraphicsUnit.Pixel);
                }
                return outBmp;
            }
        }

        // ---------- Hit testing ----------

        public bool Hit(PointF p, float tolerance)
        {
            switch (Kind)
            {
                case Tool.Arrow:
                case Tool.Line:
                    return Points.Count >= 2 && DistanceToSegment(p, Points[0], Points[1]) < Math.Max(tolerance, Width);
                case Tool.Pen:
                    for (var i = 1; i < Points.Count; i++) if (DistanceToSegment(p, Points[i - 1], Points[i]) < Math.Max(tolerance, Width)) return true;
                    return false;
                case Tool.Counter:
                    return RectangleF.Inflate(CounterRect, 2, 2).Contains(p);
                case Tool.Rectangle:
                case Tool.Ellipse:
                    if (Filled) return RectangleF.Inflate(Rect, tolerance, tolerance).Contains(p);
                    var t = Math.Max(tolerance, Width);
                    var outer = RectangleF.Inflate(Rect, t, t); var inner = RectangleF.Inflate(Rect, -t, -t);
                    return outer.Contains(p) && (inner.Width <= 0 || inner.Height <= 0 || !inner.Contains(p));
                default:
                    return RectangleF.Inflate(Rect, tolerance, tolerance).Contains(p);
            }
        }

        public int HandleAt(PointF p, float radius)
        {
            var hs = Handles;
            for (var i = 0; i < hs.Length; i++)
                if (Math.Abs(hs[i].X - p.X) <= radius && Math.Abs(hs[i].Y - p.Y) <= radius) return i;
            return -1;
        }

        static float DistanceToSegment(PointF p, PointF a, PointF b)
        {
            float dx = b.X - a.X, dy = b.Y - a.Y, len = dx * dx + dy * dy;
            if (len <= 0) return (float)Math.Sqrt((p.X - a.X) * (p.X - a.X) + (p.Y - a.Y) * (p.Y - a.Y));
            var t = Math.Max(0, Math.Min(1, ((p.X - a.X) * dx + (p.Y - a.Y) * dy) / len));
            float px = a.X + t * dx, py = a.Y + t * dy;
            return (float)Math.Sqrt((p.X - px) * (p.X - px) + (p.Y - py) * (p.Y - py));
        }
    }
}
