using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Media;
using System.Windows.Forms;

namespace Parker
{
    /// <summary>Screen grabbing (physical pixels; the app is Per-Monitor V2 DPI aware).</summary>
    internal static class ScreenGrab
    {
        public static Rectangle VirtualScreen { get { return SystemInformation.VirtualScreen; } }

        /// <summary>Copies a rectangle of the desktop (virtual-screen coordinates).</summary>
        public static Bitmap Capture(Rectangle rect)
        {
            if (rect.Width <= 0 || rect.Height <= 0) return null;
            var bmp = new Bitmap(rect.Width, rect.Height, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(bmp))
            {
                g.CopyFromScreen(rect.Location, Point.Empty, rect.Size, CopyPixelOperation.SourceCopy);
            }
            return bmp;
        }

        public static Bitmap CaptureVirtualScreen()
        {
            return Capture(VirtualScreen);
        }

        public static Screen ScreenUnderCursor()
        {
            return Screen.FromPoint(Cursor.Position);
        }

        /// <summary>Crops a virtual-screen rectangle out of a full virtual-screen snapshot.</summary>
        public static Bitmap Crop(Bitmap virtualSnapshot, Rectangle rect)
        {
            var vs = VirtualScreen;
            var local = new Rectangle(rect.X - vs.X, rect.Y - vs.Y, rect.Width, rect.Height);
            local.Intersect(new Rectangle(0, 0, virtualSnapshot.Width, virtualSnapshot.Height));
            if (local.Width <= 0 || local.Height <= 0) return null;
            return virtualSnapshot.Clone(local, PixelFormat.Format32bppArgb);
        }
    }

    /// <summary>Saving, clipboard and feedback after a capture.</summary>
    internal static class ImageStore
    {
        public static string NewFilePath(string extension)
        {
            var folder = Settings.Current.SaveFolder;
            try { Directory.CreateDirectory(folder); }
            catch
            {
                folder = Settings.DefaultSaveFolder();
                Directory.CreateDirectory(folder);
            }
            var name = "Capture " + DateTime.Now.ToString("yyyy-MM-dd 'à' HH.mm.ss");
            var path = Path.Combine(folder, name + "." + extension);
            var n = 2;
            while (File.Exists(path)) path = Path.Combine(folder, name + " (" + n++ + ")." + extension);
            return path;
        }

        public static string Save(Image image)
        {
            var jpg = Settings.Current.ImageFormat == "jpg";
            var path = NewFilePath(jpg ? "jpg" : "png");
            SaveTo(image, path);
            return path;
        }

        public static void SaveTo(Image image, string path)
        {
            var ext = Path.GetExtension(path).ToLowerInvariant();
            if (ext == ".jpg" || ext == ".jpeg")
            {
                var codec = ImageCodecInfo.GetImageEncoders().First(c => c.FormatID == ImageFormat.Jpeg.Guid);
                using (var p = new EncoderParameters(1))
                {
                    p.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, (long)Settings.Current.JpegQuality);
                    // JPEG has no alpha: flatten on white
                    using (var flat = new Bitmap(image.Width, image.Height, PixelFormat.Format24bppRgb))
                    {
                        using (var g = Graphics.FromImage(flat))
                        {
                            g.Clear(Color.White);
                            g.DrawImage(image, 0, 0, image.Width, image.Height);
                        }
                        flat.Save(path, codec, p);
                    }
                }
            }
            else
            {
                image.Save(path, ImageFormat.Png);
            }
        }

        public static void CopyImage(Image image)
        {
            for (var attempt = 0; attempt < 3; attempt++)
            {
                try
                {
                    var data = new DataObject();
                    data.SetImage(image);
                    // PNG copy too, so apps that support transparency get it
                    var ms = new MemoryStream();
                    image.Save(ms, ImageFormat.Png);
                    data.SetData("PNG", false, ms);
                    Clipboard.SetDataObject(data, true);
                    return;
                }
                catch { System.Threading.Thread.Sleep(60); }
            }
        }

        public static void CopyFile(string path)
        {
            try
            {
                using (var img = LoadUnlocked(path))
                {
                    var data = new DataObject();
                    if (img != null) data.SetImage(img);
                    data.SetFileDropList(new System.Collections.Specialized.StringCollection { path });
                    Clipboard.SetDataObject(data, true);
                }
            }
            catch { }
        }

        /// <summary>Loads an image without keeping the file locked (so it can be renamed/deleted).</summary>
        public static Bitmap LoadUnlocked(string path)
        {
            try
            {
                var bytes = File.ReadAllBytes(path);
                using (var ms = new MemoryStream(bytes))
                using (var img = Image.FromStream(ms))
                {
                    return new Bitmap(img);
                }
            }
            catch { return null; }
        }

        public static void PlayShutter()
        {
            if (!Settings.Current.PlaySound) return;
            try
            {
                var media = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Media", "Windows Navigation Start.wav");
                if (File.Exists(media)) new SoundPlayer(media).Play();
                else SystemSounds.Asterisk.Play();
            }
            catch { }
        }

        /// <summary>Common end of every capture: save, copy, sound, history.</summary>
        public static string Finish(Bitmap image)
        {
            if (image == null) return null;
            var path = Save(image);
            if (Settings.Current.CopyToClipboard) CopyImage(image);
            PlayShutter();
            Settings.Current.AddRecent(path);
            return path;
        }
    }
}
