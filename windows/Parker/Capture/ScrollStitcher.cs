using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace Parker
{
    /// <summary>
    /// Incremental stitcher for scrolling captures (same algorithm as the Mac version).
    ///
    /// Each frame is reduced to a 64-column grayscale signature. Sticky header/footer rows are
    /// detected, the scroll delta is searched in the moving band only, and only newly revealed
    /// rows are appended. Positions are tracked in "content" coordinates (rows of the final image),
    /// which allows two recoveries:
    ///  - batches: frames received while the stitcher was busy are kept, and when the newest one
    ///    jumped too far, the intermediate frames bridge the gap;
    ///  - re-anchoring: a frame that no longer overlaps the reference (scrolled too far, or back up)
    ///    is searched in the already stitched content, so the capture resumes on its own as soon as
    ///    the view shows something already captured.
    /// Not thread-safe: use from a single thread at a time.
    /// </summary>
    internal sealed class ScrollStitcher : IDisposable
    {
        public enum Result { First, Appended, Repositioned, Unchanged, NoMatch }

        const int Cols = 64, IgnoreLeft = 1, IgnoreRight = 2;
        const int Used = Cols - IgnoreLeft - IgnoreRight;
        const double VerifyThreshold = 4.0;

        Bitmap refFrame;
        int[] refGray;
        int refTop;                 // content row displayed at row 0 of the reference frame
        int contentBottom;          // content rows stitched so far (sticky footer excluded)
        int lastFooter = int.MaxValue;
        bool started;
        readonly List<Bitmap> slices = new List<Bitmap>();
        Bitmap footer;
        int[] contentGray = new int[0];

        public int LastDelta { get; private set; }

        public int TotalHeight
        {
            get
            {
                if (!started) return refFrame != null ? refFrame.Height : 0;
                return contentBottom + (footer != null ? footer.Height : 0);
            }
        }

        /// <summary>Single frame. Takes ownership of <paramref name="frame"/>.</summary>
        public Result Add(Bitmap frame, int? expectedDelta)
        {
            return AddBatch(new List<Bitmap> { frame }, expectedDelta);
        }

        /// <summary>
        /// Frames captured since the last call, oldest first. Takes ownership of all of them
        /// (the one kept as reference is retained, the others are disposed).
        /// <paramref name="expectedDelta"/> applies to the newest frame (auto-scroll).
        /// </summary>
        public Result AddBatch(IList<Bitmap> frames, int? expectedDelta)
        {
            if (frames == null || frames.Count == 0) return Result.Unchanged;
            var n = frames.Count;
            var grays = new int[n][];
            Func<int, int[]> grayOf = i => grays[i] ?? (grays[i] = GrayRows(frames[i]));

            var result = Result.NoMatch;
            var progressed = false;
            var lo = 0;
            int? expected = expectedDelta;
            try
            {
                while (true)
                {
                    var r = Match(frames[n - 1], grayOf(n - 1), expected);
                    expected = null;
                    if (r != Result.NoMatch) { result = r; break; }

                    // The newest frame jumped too far: bridge the gap with intermediate frames
                    var found = -1;
                    for (var i = n - 2; i >= lo; i--)
                    {
                        var ri = Match(frames[i], grayOf(i), null);
                        if (ri == Result.Appended || ri == Result.Repositioned || ri == Result.First) { found = i; break; }
                        if (ri == Result.Unchanged) break; // older frames are even closer to the reference
                    }
                    if (found >= 0) { progressed = true; lo = found + 1; continue; }

                    // Last resort: find the newest frame in what was already stitched
                    result = Reanchor(frames[n - 1], grayOf(n - 1));
                    break;
                }
            }
            finally
            {
                foreach (var f in frames) if (!ReferenceEquals(f, refFrame)) f.Dispose();
            }
            if (result == Result.NoMatch && progressed) return Result.NoMatch;
            if ((result == Result.Unchanged || result == Result.Repositioned) && progressed) return Result.Appended;
            return result;
        }

        // ---------- Matching against the reference frame ----------

        Result Match(Bitmap frame, int[] gray, int? expectedDelta)
        {
            if (refFrame == null) { Adopt(frame, gray, 0); return Result.First; }
            if (frame.Width != refFrame.Width || frame.Height != refFrame.Height) return Result.NoMatch;

            int h = frame.Height, header, foot;
            if (Bands(gray, h, out header, out foot)) return Result.Unchanged;

            var band = h - header - foot;
            if (band < 40) return Result.NoMatch;
            var minOverlap = Math.Max(12, band / 10);
            var maxDelta = band - minOverlap;
            if (maxDelta < 1) return Result.NoMatch;

            // Coarse search (sampled rows), then full verification of the best candidates
            var step = Math.Max(2, band / 300);
            var scores = new double[maxDelta + 1];
            var minScore = double.MaxValue;
            for (var d = 1; d <= maxDelta; d++)
            {
                long sum = 0; var count = 0;
                for (var y = header; y < h - foot - d; y += step) { sum += RowDiff(gray, y, refGray, y + d); count++; }
                scores[d] = count > 0 ? (double)sum / (count * Used) : double.MaxValue;
                if (scores[d] < minScore) minScore = scores[d];
            }
            if (minScore == double.MaxValue) return Result.NoMatch;

            // Near-equal scores (blank areas): the expected delta, else the previous one (steady scrolling)
            var prefer = expectedDelta ?? (LastDelta > 0 ? (int?)LastDelta : null);
            var order = Candidates(scores, 1, maxDelta, minScore, prefer);
            var best = -1;
            foreach (var d in order)
            {
                long fs = 0; var fc = 0;
                for (var y = header; y < h - foot - d; y++) { fs += RowDiff(gray, y, refGray, y + d); fc++; }
                if ((double)fs / (Math.Max(fc, 1) * Used) <= VerifyThreshold) { best = d; break; }
            }
            if (best <= 0) return Result.NoMatch;

            if (!started) Start(foot);
            if (refTop + best + header > contentBottom) return Result.NoMatch; // would leave a gap
            var appended = Place(frame, gray, refTop + best, header, foot);
            LastDelta = best;
            return appended ? Result.Appended : Result.Repositioned;
        }

        // ---------- Re-anchoring in the stitched content ----------

        Result Reanchor(Bitmap frame, int[] gray)
        {
            if (!started || refFrame == null) return Result.NoMatch;
            if (frame.Width != refFrame.Width || frame.Height != refFrame.Height) return Result.NoMatch;

            int h = frame.Height, header, foot;
            if (Bands(gray, h, out header, out foot)) return Result.Unchanged;
            var band = h - header - foot;
            if (band < 40) return Result.NoMatch;
            var minOverlap = Math.Max(24, band / 4);

            // Window: the last few screens of content (where the user can plausibly be)
            var hi = contentBottom - header - minOverlap;
            var lo = Math.Max(0, contentBottom - 5 * h);
            if (hi < lo) return Result.NoMatch;

            var step = Math.Max(3, band / 200);
            var scores = new double[hi - lo + 1];
            var minScore = double.MaxValue;
            for (var top = lo; top <= hi; top++)
            {
                var end = Math.Min(h - foot, contentBottom - top);
                long sum = 0; var count = 0;
                for (var y = header; y < end; y += step) { sum += RowDiff(gray, y, contentGray, top + y); count++; }
                var s = count > 0 ? (double)sum / (count * Used) : double.MaxValue;
                scores[top - lo] = s;
                if (s < minScore) minScore = s;
            }
            if (minScore == double.MaxValue) return Result.NoMatch;

            // Blank areas match everywhere: refuse when near-equal candidates are far apart
            int firstNear = -1, lastNear = -1;
            for (var i = 0; i < scores.Length; i++)
                if (scores[i] <= minScore + 0.25) { if (firstNear < 0) firstNear = i; lastNear = i; }
            if (lastNear - firstNear > band / 2) return Result.NoMatch;

            var order = Candidates(scores, 0, scores.Length - 1, minScore, refTop - lo);
            foreach (var idx in order)
            {
                var top = idx + lo;
                var end = Math.Min(h - foot, contentBottom - top);
                long fs = 0; var fc = 0;
                for (var y = header; y < end; y++) { fs += RowDiff(gray, y, contentGray, top + y); fc++; }
                if (fc < minOverlap) continue;
                if ((double)fs / (fc * Used) > VerifyThreshold) continue;
                return Place(frame, gray, top, header, foot) ? Result.Appended : Result.Repositioned;
            }
            return Result.NoMatch;
        }

        // ---------- Helpers ----------

        /// <summary>Header/footer detection against the reference. Returns true when the frame is unchanged.</summary>
        bool Bands(int[] gray, int h, out int header, out int foot)
        {
            long total = 0;
            var same = new bool[h];
            for (var y = 0; y < h; y++)
            {
                var s = RowDiff(refGray, y, gray, y);
                total += s;
                same[y] = s < 2 * Used;
            }
            header = 0; foot = 0;
            if (total < (long)h * Used) return true;
            while (header < h / 3 && same[header]) header++;
            while (foot < h / 4 && same[h - 1 - foot]) foot++;
            // The sticky footer can only shrink: blank content rows above a footer look "unchanged"
            // on small scrolls, and letting the footer grow would duplicate those rows.
            if (started) foot = Math.Min(foot, lastFooter);
            return false;
        }

        /// <summary>
        /// Up to 3 verification candidates: among near-equal scores, closest to <paramref name="prefer"/>
        /// first (or lowest score when there is no preference), then the next best distinct scores.
        /// </summary>
        static List<int> Candidates(double[] scores, int from, int to, double minScore, int? prefer)
        {
            var list = new List<int>();
            var best = -1;
            for (var d = from; d <= to; d++)
            {
                if (scores[d] > minScore + 0.25) continue;
                if (best < 0) { best = d; continue; }
                if (prefer.HasValue) { if (Math.Abs(d - prefer.Value) < Math.Abs(best - prefer.Value)) best = d; }
                else if (scores[d] < scores[best]) best = d;
            }
            if (best >= 0) list.Add(best);
            for (var k = 0; k < 2; k++)
            {
                var next = -1;
                for (var d = from; d <= to; d++)
                {
                    var far = true;
                    foreach (var c in list) if (Math.Abs(c - d) <= 2) { far = false; break; }
                    if (!far) continue;
                    if (next < 0 || scores[d] < scores[next]) next = d;
                }
                if (next < 0 || scores[next] == double.MaxValue) break;
                list.Add(next);
            }
            return list;
        }

        void Start(int foot)
        {
            var h = refFrame.Height;
            slices.Add(CopyRows(refFrame, 0, h - foot));
            AppendGray(refGray, 0, h - foot);
            contentBottom = h - foot;
            refTop = 0;
            started = true;
        }

        /// <summary>Makes <paramref name="frame"/> the reference at content row <paramref name="top"/>; appends rows below the content.</summary>
        bool Place(Bitmap frame, int[] gray, int top, int header, int foot)
        {
            var h = frame.Height;
            var start = Math.Max(header, contentBottom - top);
            var end = h - foot;
            var appended = false;
            if (end > start)
            {
                slices.Add(CopyRows(frame, start, end));
                AppendGray(gray, start, end);
                contentBottom = top + end;
                if (footer != null) footer.Dispose();
                footer = foot > 0 ? CopyRows(frame, h - foot, h) : null;
                appended = true;
            }
            Adopt(frame, gray, top);
            lastFooter = foot;
            return appended;
        }

        void Adopt(Bitmap frame, int[] gray, int top)
        {
            if (refFrame != null && !ReferenceEquals(refFrame, frame)) refFrame.Dispose();
            refFrame = frame;
            refGray = gray;
            refTop = top;
        }

        void AppendGray(int[] gray, int fromRow, int toRow)
        {
            var needed = (contentBottom + (toRow - fromRow)) * Cols;
            if (contentGray.Length < needed)
            {
                var grown = new int[Math.Max(needed, contentGray.Length * 2)];
                Array.Copy(contentGray, grown, contentBottom * Cols);
                contentGray = grown;
            }
            Array.Copy(gray, fromRow * Cols, contentGray, contentBottom * Cols, (toRow - fromRow) * Cols);
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
                g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.Half;
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
            contentBottom = 0; refTop = 0; contentGray = new int[0];
        }
    }
}
