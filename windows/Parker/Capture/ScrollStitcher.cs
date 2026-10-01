using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace Parker
{
    /// <summary>
    /// Incremental stitcher for scrolling captures (same algorithm as the Mac version):
    /// each frame is reduced to a 64-column grayscale signature; sticky header/footer rows are
    /// detected, the scroll delta is searched in the moving band only, and only newly revealed
    /// rows are appended. On a failed match the reference frame is kept, so scrolling back a bit
    /// lets the capture resume.
    /// </summary>
    internal sealed class ScrollStitcher : IDisposable
    {
        public enum Result { First, Appended, Unchanged, NoMatch }

        const int Cols = 64, IgnoreLeft = 1, IgnoreRight = 2;
        const int Used = Cols - IgnoreLeft - IgnoreRight;

        Bitmap refFrame;
        int[] refGray;
        int refBandBottom;
        int lastFooter = int.MaxValue;
        bool started;
        readonly List<Bitmap> slices = new List<Bitmap>();
        Bitmap footer;

        public int LastDelta { get; private set; }

        public int TotalHeight
        {
            get
            {
                if (!started) return refFrame != null ? refFrame.Height : 0;
                var h = 0;
                foreach (var s in slices) h += s.Height;
                return h + (footer != null ? footer.Height : 0);
            }
        }

        /// <summary>Takes ownership of <paramref name="frame"/>.</summary>
        public Result Add(Bitmap frame, int? expectedDelta)
        {
            var gray = GrayRows(frame);
            if (refFrame == null)
            {
                refFrame = frame;
                refGray = gray;
                return Result.First;
            }
            if (frame.Width != refFrame.Width || frame.Height != refFrame.Height) { frame.Dispose(); return Result.NoMatch; }

            var h = frame.Height;
            long total = 0;
            var same = new bool[h];
            for (var y = 0; y < h; y++)
            {
                var s = RowDiff(refGray, y, gray, y);
                total += s;
                same[y] = s < 2 * Used;
            }
            if (total < (long)h * Used) { frame.Dispose(); return Result.Unchanged; }

            var header = 0;
            while (header < h / 3 && same[header]) header++;
            var foot = 0;
            while (foot < h / 4 && same[h - 1 - foot]) foot++;
            // The sticky footer can only shrink: blank content rows above a footer look "unchanged"
            // on small scrolls, and letting the footer grow would duplicate those rows.
            if (started) foot = Math.Min(foot, lastFooter);

            var band = h - header - foot;
            if (band < 40) { frame.Dispose(); return Result.NoMatch; }
            var minOverlap = Math.Max(12, band / 10);
            var maxDelta = band - minOverlap;
            if (maxDelta < 1) { frame.Dispose(); return Result.NoMatch; }

            var scores = new double[maxDelta + 1];
            var minScore = double.MaxValue;
            for (var d = 1; d <= maxDelta; d++)
            {
                long sum = 0; var count = 0;
                for (var y = header; y < h - foot - d; y += 2) { sum += RowDiff(gray, y, refGray, y + d); count++; }
                scores[d] = count > 0 ? (double)sum / (count * Used) : double.MaxValue;
                if (scores[d] < minScore) minScore = scores[d];
            }
            if (minScore == double.MaxValue) { frame.Dispose(); return Result.NoMatch; }

            var best = -1;
            for (var d = 1; d <= maxDelta; d++)
            {
                if (scores[d] > minScore + 0.25) continue;
                if (best < 0) { best = d; continue; }
                if (expectedDelta.HasValue)
                {
                    if (Math.Abs(d - expectedDelta.Value) < Math.Abs(best - expectedDelta.Value)) best = d;
                }
                else if (scores[d] < scores[best]) best = d;
            }
            if (best <= 0) { frame.Dispose(); return Result.NoMatch; }

            long fs = 0; var fc = 0;
            for (var y = header; y < h - foot - best; y++) { fs += RowDiff(gray, y, refGray, y + best); fc++; }
            if ((double)fs / (Math.Max(fc, 1) * Used) > 4.0) { frame.Dispose(); return Result.NoMatch; }

            if (!started)
            {
                slices.Add(CopyRows(refFrame, 0, h - foot));
                refBandBottom = h - foot;
                started = true;
            }
            var start = Math.Max(0, refBandBottom - best);
            var end = h - foot;
            if (end > start) slices.Add(CopyRows(frame, start, end));
            if (footer != null) footer.Dispose();
            footer = foot > 0 ? CopyRows(frame, h - foot, h) : null;

            refFrame.Dispose();
            refFrame = frame;
            refGray = gray;
            refBandBottom = end;
            lastFooter = foot;
            LastDelta = best;
            return Result.Appended;
        }

        public Bitmap Compose(int maxWidth = 0)
        {
            if (refFrame == null) return null;
            var parts = new List<Bitmap>();
            if (started) { parts.AddRange(slices); if (footer != null) parts.Add(footer); }
            else parts.Add(refFrame);

            var width = refFrame.Width;
            var totalH = 0;
            foreach (var p in parts) totalH += p.Height;
            var scale = maxWidth > 0 && width > maxWidth ? (double)maxWidth / width : 1.0;
            var outW = Math.Max(1, (int)Math.Round(width * scale));
            var outH = Math.Max(1, (int)Math.Round(totalH * scale));

            var result = new Bitmap(outW, outH, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(result))
            {
                g.InterpolationMode = scale < 1 ? System.Drawing.Drawing2D.InterpolationMode.HighQualityBilinear : System.Drawing.Drawing2D.InterpolationMode.NearestNeighbor;
                var y = 0.0;
                foreach (var p in parts)
                {
                    var h = p.Height * scale;
                    g.DrawImage(p, new RectangleF(0, (float)y, outW, (float)h));
                    y += h;
                }
            }
            return result;
        }

        static int RowDiff(int[] a, int rowA, int[] b, int rowB)
        {
            var oa = rowA * Cols; var ob = rowB * Cols; var s = 0;
            for (var c = IgnoreLeft; c < Cols - IgnoreRight; c++) s += Math.Abs(a[oa + c] - b[ob + c]);
            return s;
        }

        /// <summary>Row-major grayscale signature, 64 columns (area average), row 0 = top.</summary>
        static int[] GrayRows(Bitmap bmp)
        {
            var w = bmp.Width; var h = bmp.Height;
            var result = new int[h * Cols];
            var data = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try
            {
                var stride = data.Stride;
                var row = new byte[Math.Abs(stride)];
                var edges = new int[Cols + 1];
                for (var c = 0; c <= Cols; c++) edges[c] = (int)((long)c * w / Cols);
                for (var y = 0; y < h; y++)
                {
                    Marshal.Copy(IntPtr.Add(data.Scan0, y * stride), row, 0, row.Length);
                    for (var c = 0; c < Cols; c++)
                    {
                        int x0 = edges[c], x1 = Math.Max(edges[c + 1], x0 + 1), sum = 0, n = 0;
                        var step = Math.Max(1, (x1 - x0) / 8);
                        for (var x = x0; x < x1 && x < w; x += step)
                        {
                            var i = x * 4;
                            sum += (row[i] * 29 + row[i + 1] * 150 + row[i + 2] * 77) >> 8; // BGRA
                            n++;
                        }
                        result[y * Cols + c] = n > 0 ? sum / n : 0;
                    }
                }
            }
            finally { bmp.UnlockBits(data); }
            return result;
        }

        /// <summary>Deep copy of rows [top, bottom), independent from the source bitmap.</summary>
        static Bitmap CopyRows(Bitmap src, int top, int bottom)
        {
            var h = bottom - top;
            var dst = new Bitmap(src.Width, h, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(dst))
            {
                g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy;
                g.DrawImage(src, new Rectangle(0, 0, src.Width, h), new Rectangle(0, top, src.Width, h), GraphicsUnit.Pixel);
            }
            return dst;
        }

        public void Dispose()
        {
            if (refFrame != null) refFrame.Dispose();
            foreach (var s in slices) s.Dispose();
            slices.Clear();
            if (footer != null) footer.Dispose();
            refFrame = null; footer = null; started = false; lastFooter = int.MaxValue;
        }
    }
}
