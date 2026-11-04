// WinDebloat Live - Windows Forms view layer in a Material 3 Expressive style.
// Compiled at start by Add-Type (Windows PowerShell 5.1 = C# 5: no string interpolation, no ?. operators).
// Light / dark follows the Windows app theme; every size is in dp and scaled with the system DPI.
// SPDX-License-Identifier: MIT
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace WdlUi
{
    public enum TextStyle { Body, BodyStrong, Label, Caption, Title, Headline, Display, Mono }
    public enum ColorRole { OnSurface, OnSurfaceVariant, Primary, OnPrimaryContainer, OnSecondaryContainer, OnTertiaryContainer, Error }
    public enum Surface { Card, CardHigh, PrimaryContainer, SecondaryContainer, TertiaryContainer }
    public enum ButtonKind { Filled, Tonal, Outlined, Text }
    public enum ToggleKind { Switch, Check, Radio }
    public enum Glyph { None, Info, Warning, Error, Question, Check }

    // ------------------------------------------------------------------ theme
    public static class Theme
    {
        public static bool Dark;
        public static float Scale = 1f;
        public static string Family = "Segoe UI";
        public static string StrongFamily = null;
        public static string DisplayFamily = null;
        public static string MonoFamily = "Consolas";
        public static string IconDir;
        public static Func<string, string> Tr;
        public static Color Bg, Card, CardHigh, OnSurface, OnSurfaceVariant, Outline, OutlineVariant, Primary, OnPrimary,
            PrimaryContainer, OnPrimaryContainer, SecondaryContainer, OnSecondaryContainer, Tertiary, TertiaryContainer,
            OnTertiaryContainer, Error, ErrorContainer, OnErrorContainer;
        static readonly Dictionary<string, Font> fonts = new Dictionary<string, Font>();
        static readonly Dictionary<string, Image> icons = new Dictionary<string, Image>();
        static string[] installed;

        public static bool IsWindows { get { return Environment.OSVersion.Platform == PlatformID.Win32NT; } }

        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr value);
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr hwnd, string app, string idList);

        // must run before the first window: crisp text instead of bitmap-stretched UI on 125-200 % displays
        public static void EnableDpiAwareness()
        {
            if (!IsWindows) return;
            try { if (SetProcessDpiAwarenessContext(new IntPtr(-2))) return; } catch (Exception) { }   // system aware
            try { SetProcessDPIAware(); } catch (Exception) { }
        }

        public static bool DetectDark()
        {
            try
            {
                object v = Microsoft.Win32.Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1);
                return v is int && (int)v == 0;
            }
            catch (Exception) { return false; }
        }

        public static void Init(bool dark, string iconDir)
        {
            Dark = dark; IconDir = iconDir;
            try { using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) { Scale = Math.Max(1f, g.DpiX / 96f); } } catch (Exception) { Scale = 1f; }
            SetFamily(null);
            if (Dark)
            {
                Bg = C(0x131318); Card = C(0x1F1F26); CardHigh = C(0x2A2A32); OnSurface = C(0xE5E1E9); OnSurfaceVariant = C(0xC6C5D3);
                Outline = C(0x90909C); OutlineVariant = C(0x45464F); Primary = C(0xBFC2FF); OnPrimary = C(0x232A7A);
                PrimaryContainer = C(0x3A4199); OnPrimaryContainer = C(0xE0E0FF); SecondaryContainer = C(0x41455F); OnSecondaryContainer = C(0xE0E1F9);
                Tertiary = C(0xFFB59A); TertiaryContainer = C(0x6E3A26); OnTertiaryContainer = C(0xFFDBCF);
                Error = C(0xFFB4AB); ErrorContainer = C(0x93000A); OnErrorContainer = C(0xFFDAD6);
            }
            else
            {
                Bg = C(0xF6F5FC); Card = C(0xFFFFFF); CardHigh = C(0xECEBF6); OnSurface = C(0x1B1B21); OnSurfaceVariant = C(0x46464F);
                Outline = C(0x777680); OutlineVariant = C(0xC7C5D0); Primary = C(0x4C55C7); OnPrimary = C(0xFFFFFF);
                PrimaryContainer = C(0xE0E0FF); OnPrimaryContainer = C(0x0F1673); SecondaryContainer = C(0xE1E0F9); OnSecondaryContainer = C(0x191A2C);
                Tertiary = C(0xA4512E); TertiaryContainer = C(0xFFDBCF); OnTertiaryContainer = C(0x380D00);
                Error = C(0xBA1A1A); ErrorContainer = C(0xFFDAD6); OnErrorContainer = C(0x410002);
            }
        }

        static Color C(int rgb) { return Color.FromArgb(255, (rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255); }
        public static int S(float dp) { return (int)Math.Round(dp * Scale); }
        public static float SF(float dp) { return dp * Scale; }
        public static string T(string key)
        {
            if (Tr == null || string.IsNullOrEmpty(key)) return key;
            try { return Tr(key); } catch (Exception) { return key; }
        }

        static bool Has(string name)
        {
            if (installed == null)
            {
                List<string> l = new List<string>();
                try { using (InstalledFontCollection c = new InstalledFontCollection()) { foreach (FontFamily f in c.Families) l.Add(f.Name); } } catch (Exception) { }
                installed = l.ToArray();
            }
            return Array.IndexOf(installed, name) >= 0;
        }

        static string First(params string[] names)
        {
            foreach (string n in names) { if (n != null && Has(n)) return n; }
            return null;
        }

        // null = Latin / Vietnamese UI (Segoe UI Variable on Windows 11, Segoe UI on Windows 10); else a script font
        public static void SetFamily(string scriptFamily)
        {
            foreach (Font f in fonts.Values) f.Dispose();
            fonts.Clear();
            MonoFamily = First("Cascadia Mono", "Consolas", "DejaVu Sans Mono") ?? "Courier New";
            if (!string.IsNullOrEmpty(scriptFamily) && Has(scriptFamily))
            {
                Family = scriptFamily; StrongFamily = null; DisplayFamily = null; return;
            }
            Family = First("Segoe UI Variable Text", "Segoe UI", "Inter", "Noto Sans", "DejaVu Sans") ?? "Microsoft Sans Serif";
            StrongFamily = First("Segoe UI Variable Text Semibold", "Segoe UI Semibold", "Inter SemiBold");
            DisplayFamily = First("Segoe UI Variable Display Semibold", "Segoe UI Semibold", "Inter SemiBold");
        }

        public static Font Font(TextStyle s)
        {
            string key = s.ToString();
            Font f;
            if (fonts.TryGetValue(key, out f)) return f;
            string fam = Family; float size = 10f; FontStyle st = FontStyle.Regular; bool strong = false, display = false;
            switch (s)
            {
                case TextStyle.Body: size = 10f; break;
                case TextStyle.BodyStrong: size = 10f; strong = true; break;
                case TextStyle.Label: size = 10f; strong = true; break;
                case TextStyle.Caption: size = 9f; break;
                case TextStyle.Title: size = 13f; strong = true; break;
                case TextStyle.Headline: size = 17f; strong = true; display = true; break;
                case TextStyle.Display: size = 26f; strong = true; display = true; break;
                case TextStyle.Mono: size = 9f; fam = MonoFamily; break;
            }
            if (display && DisplayFamily != null) fam = DisplayFamily;
            else if (strong && StrongFamily != null) fam = StrongFamily;
            else if (strong) st = FontStyle.Bold;
            f = new Font(fam, size, st, GraphicsUnit.Point);
            fonts[key] = f;
            return f;
        }

        public static Color Role(ColorRole r)
        {
            switch (r)
            {
                case ColorRole.OnSurfaceVariant: return OnSurfaceVariant;
                case ColorRole.Primary: return Primary;
                case ColorRole.OnPrimaryContainer: return OnPrimaryContainer;
                case ColorRole.OnSecondaryContainer: return OnSecondaryContainer;
                case ColorRole.OnTertiaryContainer: return OnTertiaryContainer;
                case ColorRole.Error: return Error;
                default: return OnSurface;
            }
        }

        public static Color Fill(Surface s)
        {
            switch (s)
            {
                case Surface.CardHigh: return CardHigh;
                case Surface.PrimaryContainer: return PrimaryContainer;
                case Surface.SecondaryContainer: return SecondaryContainer;
                case Surface.TertiaryContainer: return TertiaryContainer;
                default: return Card;
            }
        }

        public static Color Mix(Color a, Color b, float t)
        {
            t = Math.Max(0f, Math.Min(1f, t));
            return Color.FromArgb((int)(a.A + (b.A - a.A) * t), (int)(a.R + (b.R - a.R) * t), (int)(a.G + (b.G - a.G) * t), (int)(a.B + (b.B - a.B) * t));
        }

        public static Color Alpha(Color c, float a) { return Color.FromArgb((int)(Math.Max(0f, Math.Min(1f, a)) * 255), c.R, c.G, c.B); }

        public static GraphicsPath Round(RectangleF r, float rad)
        {
            GraphicsPath p = new GraphicsPath();
            rad = Math.Max(0.5f, Math.Min(rad, Math.Min(r.Width, r.Height) / 2f));
            float d = rad * 2f;
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        // first opaque background up the parent chain
        public static Color BackOf(Control c)
        {
            for (Control x = c; x != null; x = x.Parent) { if (x.BackColor.A == 255) return x.BackColor; }
            return Bg;
        }

        public static void Smooth(Graphics g)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        }

        // monochrome icon from assets\icons, nearest size at or above the requested pixels
        public static Image Icon(string name, int px)
        {
            if (string.IsNullOrEmpty(name) || IconDir == null) return null;
            int[] sizes = new int[] { 16, 20, 24, 32, 40, 48 };
            int pick = sizes[sizes.Length - 1];
            foreach (int s in sizes) { if (s >= px) { pick = s; break; } }
            string key = name + "_" + pick;
            Image img;
            if (icons.TryGetValue(key, out img)) return img;
            string path = Path.Combine(IconDir, key + ".png");
            img = null;
            try { if (File.Exists(path)) { using (MemoryStream ms = new MemoryStream(File.ReadAllBytes(path))) using (Image i = Image.FromStream(ms)) { img = new Bitmap(i); } } } catch (Exception) { img = null; }
            icons[key] = img;
            return img;
        }

        // draws a monochrome icon tinted with the content color (keeps the alpha of the artwork)
        public static void DrawIcon(Graphics g, string name, RectangleF r, Color c)
        {
            Image img = Icon(name, (int)Math.Ceiling(r.Width));
            if (img == null) return;
            ColorMatrix m = new ColorMatrix(new float[][] {
                new float[] { 0, 0, 0, 0, 0 }, new float[] { 0, 0, 0, 0, 0 }, new float[] { 0, 0, 0, 0, 0 },
                new float[] { 0, 0, 0, c.A / 255f, 0 }, new float[] { c.R / 255f, c.G / 255f, c.B / 255f, 0, 1 } });
            using (ImageAttributes a = new ImageAttributes())
            {
                a.SetColorMatrix(m);
                g.DrawImage(img, new Rectangle((int)r.X, (int)r.Y, (int)Math.Round(r.Width), (int)Math.Round(r.Height)), 0, 0, img.Width, img.Height, GraphicsUnit.Pixel, a);
            }
        }

        public static void DrawGlyph(Graphics g, Glyph k, RectangleF r, Color c)
        {
            float w = r.Width;
            using (Pen p = new Pen(c, Math.Max(1.5f, w / 11f)))
            {
                p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; p.LineJoin = LineJoin.Round;
                switch (k)
                {
                    case Glyph.Check:
                        g.DrawLines(p, new PointF[] { new PointF(r.X + w * 0.2f, r.Y + w * 0.52f), new PointF(r.X + w * 0.42f, r.Y + w * 0.72f), new PointF(r.X + w * 0.8f, r.Y + w * 0.3f) });
                        break;
                    case Glyph.Warning:
                        g.DrawPolygon(p, new PointF[] { new PointF(r.X + w * 0.5f, r.Y + w * 0.12f), new PointF(r.X + w * 0.92f, r.Y + w * 0.86f), new PointF(r.X + w * 0.08f, r.Y + w * 0.86f) });
                        g.DrawLine(p, r.X + w * 0.5f, r.Y + w * 0.4f, r.X + w * 0.5f, r.Y + w * 0.6f);
                        g.DrawLine(p, r.X + w * 0.5f, r.Y + w * 0.73f, r.X + w * 0.5f, r.Y + w * 0.74f);
                        break;
                    case Glyph.Error:
                        g.DrawEllipse(p, r.X + w * 0.1f, r.Y + w * 0.1f, w * 0.8f, w * 0.8f);
                        g.DrawLine(p, r.X + w * 0.36f, r.Y + w * 0.36f, r.X + w * 0.64f, r.Y + w * 0.64f);
                        g.DrawLine(p, r.X + w * 0.64f, r.Y + w * 0.36f, r.X + w * 0.36f, r.Y + w * 0.64f);
                        break;
                    case Glyph.Question:
                        g.DrawEllipse(p, r.X + w * 0.1f, r.Y + w * 0.1f, w * 0.8f, w * 0.8f);
                        g.DrawArc(p, r.X + w * 0.37f, r.Y + w * 0.26f, w * 0.26f, w * 0.24f, 180, 250);
                        g.DrawLine(p, r.X + w * 0.5f, r.Y + w * 0.5f, r.X + w * 0.5f, r.Y + w * 0.56f);
                        g.DrawLine(p, r.X + w * 0.5f, r.Y + w * 0.7f, r.X + w * 0.5f, r.Y + w * 0.71f);
                        break;
                    case Glyph.Info:
                        g.DrawEllipse(p, r.X + w * 0.1f, r.Y + w * 0.1f, w * 0.8f, w * 0.8f);
                        g.DrawLine(p, r.X + w * 0.5f, r.Y + w * 0.46f, r.X + w * 0.5f, r.Y + w * 0.68f);
                        g.DrawLine(p, r.X + w * 0.5f, r.Y + w * 0.31f, r.X + w * 0.5f, r.Y + w * 0.32f);
                        break;
                }
            }
        }

        // dark title bar / rounded corners / caption color (Windows 10 2004+ / 11; ignored elsewhere)
        public static void StyleWindow(Form f)
        {
            if (!IsWindows) return;
            try
            {
                int on = Dark ? 1 : 0;
                if (DwmSetWindowAttribute(f.Handle, 20, ref on, 4) != 0) DwmSetWindowAttribute(f.Handle, 19, ref on, 4);
                int round = 2; DwmSetWindowAttribute(f.Handle, 33, ref round, 4);
                int cap = Bg.R | (Bg.G << 8) | (Bg.B << 16); DwmSetWindowAttribute(f.Handle, 35, ref cap, 4);
            }
            catch (Exception) { }
        }

        public static void StyleScrollBars(Control c)
        {
            if (!IsWindows || !c.IsHandleCreated) return;
            try { SetWindowTheme(c.Handle, Dark ? "DarkMode_Explorer" : "Explorer", null); } catch (Exception) { }
        }

        // colors, fonts and texts for a whole window (also after a language switch)
        public static void Apply(Control root)
        {
            if (root is Form) { root.BackColor = Bg; root.ForeColor = OnSurface; root.Font = Font(TextStyle.Body); }
            ApplyTree(root);
            root.PerformLayout();
            root.Invalidate(true);
        }

        static void ApplyTree(Control c)
        {
            string tag = c.Tag as string;
            if (tag != null && tag.StartsWith("@")) c.Text = T(tag.Substring(1));
            IThemed t = c as IThemed;
            if (t != null) t.ApplyTheme();
            else if (c is TextBox) { c.BackColor = BackOf(c.Parent); c.ForeColor = OnSurface; }
            else if (c is Panel || c is PictureBox) c.BackColor = BackOf(c.Parent);
            else if (c is ComboBox) { ComboBox cb = (ComboBox)c; cb.FlatStyle = FlatStyle.Flat; cb.BackColor = CardHigh; cb.ForeColor = OnSurface; cb.Font = Font(TextStyle.Body); }
            if (c is TextBox) StyleScrollBars(c);
            foreach (Control x in c.Controls) ApplyTree(x);
        }
    }

    public interface IThemed { void ApplyTheme(); }

    // ------------------------------------------------------------------ text
    public class WdlLabel : Label, IThemed
    {
        TextStyle style = TextStyle.Body;
        ColorRole role = ColorRole.OnSurface;
        string iconName;
        Glyph glyph;
        public bool Wrap;
        public WdlLabel() { AutoSize = true; UseMnemonic = false; BackColor = Color.Transparent; }
        public WdlLabel(string text, TextStyle s, ColorRole r) : this()
        {
            if (text != null && text.StartsWith("@")) { Tag = text; Text = Theme.T(text.Substring(1)); } else Text = text;
            style = s; role = r; ApplyTheme();
        }
        public TextStyle Style { get { return style; } set { style = value; ApplyTheme(); } }
        public ColorRole Role { get { return role; } set { role = value; ApplyTheme(); } }
        public string IconName { get { return iconName; } set { iconName = value; ApplyTheme(); } }
        public Glyph Glyph { get { return glyph; } set { glyph = value; ApplyTheme(); } }
        public void ApplyTheme()
        {
            Font = Theme.Font(style); ForeColor = Theme.Role(role);
            bool icon = iconName != null || glyph != Glyph.None;
            Padding = icon ? new Padding(Theme.S(style == TextStyle.Title ? 32 : 26), 0, 0, 0) : Padding.Empty;
            FitWidth();
        }
        protected override void OnParentChanged(EventArgs e)
        {
            base.OnParentChanged(e);
            if (Parent != null) Parent.Resize += delegate { FitWidth(); };
            FitWidth();
        }
        // wrapping labels take the width of their container
        public void FitWidth()
        {
            if (!Wrap || Parent == null) return;
            int w = Parent.ClientSize.Width - Parent.Padding.Horizontal - Margin.Horizontal - Theme.S(4);
            if (w > 50) MaximumSize = new Size(w, 0);
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            if (iconName == null && glyph == Glyph.None) return;
            Theme.Smooth(e.Graphics);
            int s = Theme.S(style == TextStyle.Title ? 24 : 18);
            int lh = TextRenderer.MeasureText("Ag", Font).Height;
            RectangleF r = new RectangleF(0, Math.Max(0, (lh - s) / 2f), s, s);
            if (iconName != null) Theme.DrawIcon(e.Graphics, iconName, r, ForeColor); else Theme.DrawGlyph(e.Graphics, glyph, r, ForeColor);
        }
    }

    // ------------------------------------------------------------------ surfaces
    public class WdlCard : Panel, IThemed
    {
        public float Radius = 24;
        public Surface Fill = Surface.Card;
        public bool Outlined;
        public bool Clickable;
        float hover, hoverTarget;
        readonly Timer anim = new Timer();
        public WdlCard()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
            Padding = new Padding(Theme.S(20));
            anim.Interval = 15;
            anim.Tick += delegate {
                hover += (hoverTarget - hover) * 0.3f;
                if (Math.Abs(hover - hoverTarget) < 0.02f) { hover = hoverTarget; anim.Stop(); }
                SyncBack();
            };
        }
        public void ApplyTheme() { if (Clickable) Cursor = Cursors.Hand; SyncBack(); }
        public Color CurrentFill
        {
            get { Color f = Theme.Fill(Fill); return Clickable && hover > 0 ? Theme.Mix(f, Theme.Primary, 0.10f * hover) : f; }
        }
        // children inherit the live card color, so hover never leaves patches behind labels or panels
        void SyncBack()
        {
            BackColor = CurrentFill;
            foreach (Control x in Controls) SyncChild(x, BackColor);
            Invalidate(true);
        }
        static void SyncChild(Control c, Color col)
        {
            if (c is WdlCard) return;
            if (c.BackColor.A == 255 && (c is Panel || c is PictureBox)) c.BackColor = col;
            foreach (Control x in c.Controls) SyncChild(x, col);
        }
        protected override void OnPaintBackground(PaintEventArgs e)
        {
            Color outer = Theme.BackOf(Parent);
            using (SolidBrush b = new SolidBrush(outer)) e.Graphics.FillRectangle(b, ClientRectangle);
            Theme.Smooth(e.Graphics);
            RectangleF r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
            Color fill = CurrentFill;
            using (GraphicsPath p = Theme.Round(r, Theme.SF(Radius)))
            {
                using (SolidBrush b = new SolidBrush(fill)) e.Graphics.FillPath(b, p);
                if (Outlined || (Clickable && hover > 0))
                {
                    Color oc = Clickable ? Theme.Alpha(Theme.Primary, hover) : Theme.OutlineVariant;
                    using (Pen pen = new Pen(oc, Math.Max(1f, Theme.SF(Clickable ? 2f : 1f)))) e.Graphics.DrawPath(pen, p);
                }
            }
        }
        // a clickable card reacts to the pointer anywhere inside, also over its child labels
        public void Hover(bool on) { if (!Clickable) return; hoverTarget = on ? 1f : 0f; anim.Start(); }
        protected override void OnControlAdded(ControlEventArgs e) { base.OnControlAdded(e); if (Clickable) Wire(e.Control); }
        void Wire(Control c)
        {
            c.MouseEnter += delegate { Hover(true); };
            c.MouseLeave += delegate { if (!ClientRectangle.Contains(PointToClient(Cursor.Position))) Hover(false); };
            c.Click += delegate { OnClick(EventArgs.Empty); };
            c.Cursor = Cursors.Hand;
            foreach (Control x in c.Controls) Wire(x);
        }
        protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); Hover(true); }
        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); if (!ClientRectangle.Contains(PointToClient(Cursor.Position))) Hover(false); }
        protected override void Dispose(bool disposing) { if (disposing) anim.Dispose(); base.Dispose(disposing); }
    }

    // ------------------------------------------------------------------ buttons
    public class WdlButton : Control, IButtonControl, IThemed
    {
        ButtonKind kind = ButtonKind.Filled;
        public string IconName;
        public bool Large;
        public bool Small;
        public bool Destructive;
        float hover, hoverTarget, press;
        bool isDefault;
        DialogResult result = DialogResult.None;
        readonly Timer anim = new Timer();

        public WdlButton()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.UserPaint
                | ControlStyles.Selectable | ControlStyles.StandardClick, true);
            Cursor = Cursors.Hand; TabStop = true; AutoSize = true;
            anim.Interval = 15;
            anim.Tick += delegate {
                bool done = true;
                if (Math.Abs(hover - hoverTarget) > 0.02f) { hover += (hoverTarget - hover) * 0.35f; done = false; } else hover = hoverTarget;
                if (press > 0) { press = Math.Max(0, press - 0.07f); done = false; }
                if (done) anim.Stop();
                Invalidate();
            };
        }
        public WdlButton(string text, ButtonKind k, string icon) : this()
        {
            if (text != null && text.StartsWith("@")) { Tag = text; Text = Theme.T(text.Substring(1)); } else Text = text;
            kind = k; IconName = icon;
        }
        public ButtonKind Kind { get { return kind; } set { kind = value; Invalidate(); } }
        public DialogResult DialogResult { get { return result; } set { result = value; } }
        public void ApplyTheme() { Font = Theme.Font(TextStyle.Label); Fit(); Invalidate(); }
        public void NotifyDefault(bool value) { isDefault = value; Invalidate(); }
        public void PerformClick() { if (Enabled && Visible) OnClick(EventArgs.Empty); }
        protected override void OnClick(EventArgs e)
        {
            Form f = FindForm();
            if (f != null && result != DialogResult.None) f.DialogResult = result;
            base.OnClick(e);
        }

        int H { get { return Theme.S(Large ? 56 : (Small ? 34 : 40)); } }
        public override Size GetPreferredSize(Size proposed)
        {
            Size t = TextRenderer.MeasureText(string.IsNullOrEmpty(Text) ? " " : Text, Font, Size.Empty, TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
            int pad = Theme.S(Large ? 30 : (Small ? 14 : 22));
            int icon = IconName != null ? Theme.S(Large ? 24 : 18) + Theme.S(8) : 0;
            return new Size(t.Width + pad * 2 + icon, Math.Max(H, t.Height + Theme.S(12)));
        }
        void Fit() { if (AutoSize) Size = GetPreferredSize(Size.Empty); }
        protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); Fit(); Invalidate(); }
        protected override void OnFontChanged(EventArgs e) { base.OnFontChanged(e); Fit(); }
        protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); if (!Enabled) { hover = 0; hoverTarget = 0; } Invalidate(); }
        protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); hoverTarget = 1; anim.Start(); }
        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); hoverTarget = 0; anim.Start(); }
        protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); if (e.Button == MouseButtons.Left) { press = 1; Focus(); anim.Start(); } }
        protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
        protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }
        protected override bool IsInputKey(Keys k) { return k == Keys.Enter || k == Keys.Space || base.IsInputKey(k); }
        protected override void OnKeyUp(KeyEventArgs e) { base.OnKeyUp(e); if (e.KeyCode == Keys.Space || e.KeyCode == Keys.Enter) { press = 1; anim.Start(); PerformClick(); } }
        protected override void OnPaintBackground(PaintEventArgs e)
        {
            Color c = Theme.BackOf(Parent);
            using (SolidBrush b = new SolidBrush(c)) e.Graphics.FillRectangle(b, ClientRectangle);
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            Theme.Smooth(g);
            Color bg = Color.Transparent, fg = Theme.Primary, outline = Color.Empty;
            Color accent = Destructive ? Theme.Error : Theme.Primary;
            switch (kind)
            {
                case ButtonKind.Filled: bg = Destructive ? Theme.Error : Theme.Primary; fg = Destructive ? Theme.ErrorContainer : Theme.OnPrimary; break;
                case ButtonKind.Tonal: bg = Theme.SecondaryContainer; fg = Theme.OnSecondaryContainer; break;
                case ButtonKind.Outlined: outline = Theme.OutlineVariant; fg = accent; break;
                case ButtonKind.Text: fg = accent; break;
            }
            if (!Enabled)
            {
                fg = Theme.Alpha(Theme.OnSurface, 0.38f);
                bg = (kind == ButtonKind.Filled || kind == ButtonKind.Tonal) ? Theme.Alpha(Theme.OnSurface, 0.10f) : Color.Transparent;
                if (outline != Color.Empty) outline = Theme.Alpha(Theme.OnSurface, 0.12f);
            }
            RectangleF r = new RectangleF(0.5f, (Height - H) / 2f + 0.5f, Width - 1.5f, H - 1.5f);
            // Expressive shape morph: pill at rest, squarer while pressed
            float rad = r.Height / 2f * (1f - 0.4f * press);
            using (GraphicsPath p = Theme.Round(r, rad))
            {
                if (bg.A > 0) using (SolidBrush b = new SolidBrush(bg)) g.FillPath(b, p);
                float layer = Enabled ? 0.08f * hover + 0.10f * press : 0f;
                if (layer > 0) using (SolidBrush b = new SolidBrush(Theme.Alpha(fg, layer))) g.FillPath(b, p);
                if (outline != Color.Empty) using (Pen pen = new Pen(Theme.Mix(outline, accent, Enabled ? hover * 0.6f : 0f), Math.Max(1f, Theme.SF(1)))) g.DrawPath(pen, p);
                if ((Focused && ShowFocusCues) || (isDefault && kind != ButtonKind.Filled && Enabled))
                    using (Pen pen = new Pen(Theme.Primary, Theme.SF(2))) g.DrawPath(pen, p);
            }
            int iconPx = IconName != null ? Theme.S(Large ? 24 : 18) : 0;
            Size ts = TextRenderer.MeasureText(Text, Font, Size.Empty, TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
            int gap = IconName != null ? Theme.S(8) : 0;
            float x = (Width - (ts.Width + iconPx + gap)) / 2f;
            if (IconName != null) Theme.DrawIcon(g, IconName, new RectangleF(x, (Height - iconPx) / 2f, iconPx, iconPx), fg);
            Rectangle tr = new Rectangle((int)(x + iconPx + gap), 0, ts.Width + 4, Height);
            TextRenderer.DrawText(g, Text, Font, tr, fg, TextFormatFlags.NoPadding | TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter | TextFormatFlags.Left);
        }
        protected override void Dispose(bool disposing) { if (disposing) anim.Dispose(); base.Dispose(disposing); }
    }

    // ------------------------------------------------------------------ switch / checkbox / radio
    public class WdlToggle : Control, IThemed
    {
        bool isChecked;
        ToggleKind kind = ToggleKind.Switch;
        float pos, hover, hoverTarget;
        readonly Timer anim = new Timer();
        public event EventHandler CheckedChanged;

        public WdlToggle()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.UserPaint
                | ControlStyles.Selectable | ControlStyles.StandardClick, true);
            Cursor = Cursors.Hand; TabStop = true; AutoSize = true;
            anim.Interval = 15;
            anim.Tick += delegate {
                float tp = isChecked ? 1f : 0f;
                pos += (tp - pos) * 0.3f; hover += (hoverTarget - hover) * 0.3f;
                if (Math.Abs(pos - tp) < 0.02f && Math.Abs(hover - hoverTarget) < 0.02f) { pos = tp; hover = hoverTarget; anim.Stop(); }
                Invalidate();
            };
        }
        public WdlToggle(string text, ToggleKind k) : this()
        {
            if (text != null && text.StartsWith("@")) { Tag = text; Text = Theme.T(text.Substring(1)); } else Text = text;
            kind = k;
        }
        public ToggleKind Kind { get { return kind; } set { kind = value; Fit(); Invalidate(); } }
        public bool Checked
        {
            get { return isChecked; }
            set
            {
                if (isChecked == value) return;
                isChecked = value;
                if (value && kind == ToggleKind.Radio && Parent != null)
                {
                    foreach (Control c in Parent.Controls) { WdlToggle o = c as WdlToggle; if (o != null && o != this && o.kind == ToggleKind.Radio) o.Checked = false; }
                }
                if (IsHandleCreated && Visible) anim.Start(); else pos = value ? 1f : 0f;
                Invalidate();
                if (CheckedChanged != null) CheckedChanged(this, EventArgs.Empty);
            }
        }
        public void ApplyTheme() { Font = Theme.Font(TextStyle.Body); Fit(); Invalidate(); }
        int GlyphW { get { return Theme.S(kind == ToggleKind.Switch ? 52 : 20); } }
        int GlyphH { get { return Theme.S(kind == ToggleKind.Switch ? 32 : 20); } }
        public override Size GetPreferredSize(Size proposed)
        {
            Size t = TextRenderer.MeasureText(string.IsNullOrEmpty(Text) ? " " : Text, Font, Size.Empty, TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
            return new Size(GlyphW + Theme.S(12) + t.Width + Theme.S(6), Math.Max(GlyphH, t.Height) + Theme.S(10));
        }
        void Fit() { if (AutoSize) Size = GetPreferredSize(Size.Empty); }
        protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); Fit(); Invalidate(); }
        protected override void OnFontChanged(EventArgs e) { base.OnFontChanged(e); Fit(); }
        protected override void OnClick(EventArgs e)
        {
            if (kind == ToggleKind.Radio) Checked = true; else Checked = !Checked;
            base.OnClick(e);
        }
        protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); hoverTarget = 1; anim.Start(); }
        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); hoverTarget = 0; anim.Start(); }
        protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
        protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }
        protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); Invalidate(); }
        protected override void OnKeyUp(KeyEventArgs e) { base.OnKeyUp(e); if (e.KeyCode == Keys.Space) OnClick(EventArgs.Empty); }
        protected override void OnPaintBackground(PaintEventArgs e)
        {
            Color c = Theme.BackOf(Parent);
            using (SolidBrush b = new SolidBrush(c)) e.Graphics.FillRectangle(b, ClientRectangle);
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            Theme.Smooth(g);
            float a = Enabled ? 1f : 0.38f;
            float gy = (Height - GlyphH) / 2f;
            RectangleF gr = new RectangleF(Theme.SF(1), gy, GlyphW - Theme.SF(2), GlyphH);
            if (kind == ToggleKind.Switch)
            {
                Color track = Theme.Mix(Theme.CardHigh, Theme.Primary, pos);
                using (GraphicsPath p = Theme.Round(gr, gr.Height / 2f))
                {
                    using (SolidBrush b = new SolidBrush(Theme.Alpha(track, a))) g.FillPath(b, p);
                    if (pos < 1f) using (Pen pen = new Pen(Theme.Alpha(Theme.Outline, a * (1f - pos)), Theme.SF(2))) g.DrawPath(pen, p);
                }
                float d = Theme.SF(16) + Theme.SF(8) * pos + (pos < 0.5f ? Theme.SF(4) * hover : 0f);
                float cx = gr.X + Theme.SF(16) + (gr.Width - Theme.SF(32)) * pos, cy = gr.Y + gr.Height / 2f;
                Color thumb = Theme.Mix(Theme.Outline, Theme.OnPrimary, pos);
                using (SolidBrush b = new SolidBrush(Theme.Alpha(thumb, a))) g.FillEllipse(b, cx - d / 2f, cy - d / 2f, d, d);
                if (pos > 0.5f) Theme.DrawGlyph(g, Glyph.Check, new RectangleF(cx - Theme.SF(8), cy - Theme.SF(8), Theme.SF(16), Theme.SF(16)), Theme.Alpha(Theme.Primary, a * (pos - 0.5f) * 2f));
            }
            else
            {
                float cx = gr.X + gr.Width / 2f, cy = gr.Y + gr.Height / 2f;
                if (hover > 0.02f && Enabled) using (SolidBrush b = new SolidBrush(Theme.Alpha(Theme.Primary, 0.10f * hover))) g.FillEllipse(b, cx - Theme.SF(16), cy - Theme.SF(16), Theme.SF(32), Theme.SF(32));
                Color on = Theme.Alpha(Theme.Primary, a), off = Theme.Alpha(Theme.OnSurfaceVariant, a);
                if (kind == ToggleKind.Check)
                {
                    RectangleF br = new RectangleF(cx - Theme.SF(9), cy - Theme.SF(9), Theme.SF(18), Theme.SF(18));
                    using (GraphicsPath p = Theme.Round(br, Theme.SF(4)))
                    {
                        if (isChecked) { using (SolidBrush b = new SolidBrush(on)) g.FillPath(b, p); Theme.DrawGlyph(g, Glyph.Check, br, Theme.OnPrimary); }
                        else using (Pen pen = new Pen(off, Theme.SF(2))) g.DrawPath(pen, p);
                    }
                }
                else
                {
                    using (Pen pen = new Pen(isChecked ? on : off, Theme.SF(2))) g.DrawEllipse(pen, cx - Theme.SF(9), cy - Theme.SF(9), Theme.SF(18), Theme.SF(18));
                    if (isChecked) using (SolidBrush b = new SolidBrush(on)) g.FillEllipse(b, cx - Theme.SF(5), cy - Theme.SF(5), Theme.SF(10), Theme.SF(10));
                }
            }
            Rectangle tr = new Rectangle(GlyphW + Theme.S(12), 0, Width - GlyphW - Theme.S(12), Height);
            TextRenderer.DrawText(g, Text, Font, tr, Theme.Alpha(Theme.OnSurface, a), TextFormatFlags.NoPadding | TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
            if (Focused && ShowFocusCues)
                using (Pen pen = new Pen(Theme.Primary, Theme.SF(1))) { pen.DashStyle = DashStyle.Dot; g.DrawRectangle(pen, tr.X - 2, 2, Math.Min(tr.Width - 1, TextRenderer.MeasureText(Text, Font).Width) + 2, Height - 5); }
        }
        protected override void Dispose(bool disposing) { if (disposing) anim.Dispose(); base.Dispose(disposing); }
    }

    // ------------------------------------------------------------------ segmented button
    public class WdlSegmented : Control, IThemed
    {
        string[] keys = new string[0];
        int selected;
        int hot = -1;
        public event EventHandler SelectedIndexChanged;
        public WdlSegmented()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.UserPaint | ControlStyles.Selectable, true);
            Cursor = Cursors.Hand; AutoSize = true; TabStop = true;
        }
        public string[] Keys { get { return keys; } set { keys = value ?? new string[0]; Fit(); Invalidate(); } }
        public int SelectedIndex
        {
            get { return selected; }
            set { if (value == selected || value < 0 || value >= keys.Length) return; selected = value; Invalidate(); if (SelectedIndexChanged != null) SelectedIndexChanged(this, EventArgs.Empty); }
        }
        public void ApplyTheme() { Font = Theme.Font(TextStyle.Label); Fit(); Invalidate(); }
        int SegW(int i) { return TextRenderer.MeasureText(Theme.T(keys[i]), Font, Size.Empty, TextFormatFlags.NoPadding).Width + Theme.S(26 + 40); }
        public override Size GetPreferredSize(Size proposed)
        {
            int w = 0; for (int i = 0; i < keys.Length; i++) w += SegW(i);
            return new Size(Math.Max(w, Theme.S(40)), Theme.S(40));
        }
        void Fit() { if (AutoSize) Size = GetPreferredSize(Size.Empty); }
        int HitTest(int x) { int acc = 0; for (int i = 0; i < keys.Length; i++) { acc += SegW(i); if (x < acc) return i; } return keys.Length - 1; }
        protected override void OnMouseMove(MouseEventArgs e) { base.OnMouseMove(e); int h = HitTest(e.X); if (h != hot) { hot = h; Invalidate(); } }
        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); hot = -1; Invalidate(); }
        protected override void OnMouseClick(MouseEventArgs e) { base.OnMouseClick(e); if (Enabled) SelectedIndex = HitTest(e.X); }
        protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); Invalidate(); }
        protected override void OnKeyUp(KeyEventArgs e)
        {
            base.OnKeyUp(e);
            if (e.KeyCode == System.Windows.Forms.Keys.Left && selected > 0) SelectedIndex = selected - 1;
            if (e.KeyCode == System.Windows.Forms.Keys.Right && selected < keys.Length - 1) SelectedIndex = selected + 1;
        }
        protected override void OnPaintBackground(PaintEventArgs e)
        {
            Color c = Theme.BackOf(Parent);
            using (SolidBrush b = new SolidBrush(c)) e.Graphics.FillRectangle(b, ClientRectangle);
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            Theme.Smooth(g);
            float a = Enabled ? 1f : 0.38f;
            RectangleF all = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
            float x = 0;
            using (GraphicsPath clip = Theme.Round(all, all.Height / 2f))
            {
                for (int i = 0; i < keys.Length; i++)
                {
                    float w = SegW(i);
                    RectangleF r = new RectangleF(x, 0, w, Height);
                    Region old = g.Clip;
                    g.SetClip(clip, CombineMode.Replace); g.IntersectClip(r);
                    if (i == selected) using (SolidBrush b = new SolidBrush(Theme.SecondaryContainer)) g.FillRectangle(b, r);
                    if (i == hot && Enabled) using (SolidBrush b = new SolidBrush(Theme.Alpha(Theme.OnSurface, 0.08f))) g.FillRectangle(b, r);
                    g.Clip = old;
                    if (i > 0) using (Pen pen = new Pen(Theme.Alpha(Theme.Outline, a), Theme.SF(1))) g.DrawLine(pen, x, 0, x, Height);
                    Color fg = Theme.Alpha(i == selected ? Theme.OnSecondaryContainer : Theme.OnSurface, a);
                    string t = Theme.T(keys[i]);
                    Size ts = TextRenderer.MeasureText(t, Font, Size.Empty, TextFormatFlags.NoPadding);
                    float cx = x + (w - ts.Width - (i == selected ? Theme.SF(26) : 0)) / 2f;
                    if (i == selected) { Theme.DrawGlyph(g, Glyph.Check, new RectangleF(cx, (Height - Theme.SF(18)) / 2f, Theme.SF(18), Theme.SF(18)), fg); cx += Theme.SF(26); }
                    TextRenderer.DrawText(g, t, Font, new Rectangle((int)cx, 0, ts.Width + 4, Height), fg, TextFormatFlags.NoPadding | TextFormatFlags.VerticalCenter);
                    x += w;
                }
                using (Pen pen = new Pen(Theme.Alpha(Theme.Outline, a), Theme.SF(1))) g.DrawPath(pen, clip);
            }
        }
    }

    // ------------------------------------------------------------------ progress
    public class WdlProgress : Control, IThemed
    {
        int value;
        public WdlProgress()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
            Height = Theme.S(14);
        }
        public int Value { get { return value; } set { int v = Math.Max(0, Math.Min(100, value)); if (v != this.value) { this.value = v; Invalidate(); } } }
        public void ApplyTheme() { Height = Theme.S(14); Invalidate(); }
        protected override void OnPaintBackground(PaintEventArgs e)
        {
            Color c = Theme.BackOf(Parent);
            using (SolidBrush b = new SolidBrush(c)) e.Graphics.FillRectangle(b, ClientRectangle);
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            Theme.Smooth(g);
            float h = Theme.SF(6), y = (Height - h) / 2f, gap = Theme.SF(4);
            float w = Width - 1f;
            float a = w * value / 100f;
            if (value > 0) using (GraphicsPath p = Theme.Round(new RectangleF(0, y, Math.Max(h, a), h), h / 2f)) using (SolidBrush b = new SolidBrush(Theme.Primary)) g.FillPath(b, p);
            float rest = value > 0 ? a + gap : 0f;
            if (w - rest > h) using (GraphicsPath p = Theme.Round(new RectangleF(rest, y, w - rest, h), h / 2f)) using (SolidBrush b = new SolidBrush(Theme.SecondaryContainer)) g.FillPath(b, p);
            if (value < 100) using (SolidBrush b = new SolidBrush(Theme.Primary)) g.FillEllipse(b, w - h + Theme.SF(1), y + Theme.SF(1), h - Theme.SF(2), h - Theme.SF(2));
        }
    }

    // ------------------------------------------------------------------ list with check boxes / single selection
    public class WdlItem
    {
        public string Title = "", Subtitle = "", Badge = "", Tooltip = "";
        public bool Checked, Warn;
        public object Tag;
        public override string ToString() { return Title; }
    }

    public class ItemCheckingEventArgs : EventArgs
    {
        public int Index; public bool NewValue; public bool Cancel;
    }

    // ------------------------------------------------------------------ scrolling base with a thin themed scroll bar
    public abstract class WdlScrollable : Control, IThemed
    {
        protected int offset;
        float barHover, barTarget;
        bool dragging; int dragStartY, dragStartOffset;
        readonly Timer anim = new Timer();
        protected WdlScrollable()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.UserPaint | ControlStyles.Selectable, true);
            TabStop = true;
            anim.Interval = 15;
            anim.Tick += delegate { barHover += (barTarget - barHover) * 0.3f; if (Math.Abs(barHover - barTarget) < 0.02f) { barHover = barTarget; anim.Stop(); } Invalidate(BarArea()); };
        }
        protected abstract int ContentHeight { get; }
        protected int MaxOffset { get { return Math.Max(0, ContentHeight - ClientSize.Height); } }
        public virtual void ApplyTheme() { BackColor = Theme.BackOf(Parent); Invalidate(); }
        protected int BarWidth { get { return Theme.S(14); } }
        protected bool HasBar { get { return MaxOffset > 0; } }
        Rectangle BarArea() { return new Rectangle(ClientSize.Width - BarWidth, 0, BarWidth, ClientSize.Height); }
        RectangleF Thumb()
        {
            float h = ClientSize.Height, ch = Math.Max(1, ContentHeight);
            float th = Math.Max(Theme.SF(36), h * h / ch);
            float y = MaxOffset == 0 ? 0 : (h - th) * offset / MaxOffset;
            float w = Theme.SF(4) + Theme.SF(4) * barHover;
            return new RectangleF(ClientSize.Width - w - Theme.SF(4), y + Theme.SF(2), w, th - Theme.SF(4));
        }
        public void ScrollTo(int y) { int o = Math.Max(0, Math.Min(MaxOffset, y)); if (o != offset) { offset = o; Invalidate(); } }
        public void ScrollToEnd() { ScrollTo(int.MaxValue); }
        protected override void OnMouseWheel(MouseEventArgs e) { base.OnMouseWheel(e); ScrollTo(offset - e.Delta * Theme.S(48) / 120); }
        protected override void OnResize(EventArgs e) { base.OnResize(e); ScrollTo(offset); }
        protected bool OverBar(Point p) { return HasBar && p.X >= ClientSize.Width - BarWidth; }
        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e); Focus();
            if (!OverBar(e.Location)) return;
            RectangleF t = Thumb();
            if (e.Y < t.Top || e.Y > t.Bottom) ScrollTo(offset + (e.Y < t.Top ? -ClientSize.Height : ClientSize.Height));
            dragging = true; dragStartY = e.Y; dragStartOffset = offset;
        }
        protected override void OnMouseUp(MouseEventArgs e) { base.OnMouseUp(e); dragging = false; }
        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            float tgt = OverBar(e.Location) || dragging ? 1f : 0f;
            if (tgt != barTarget) { barTarget = tgt; anim.Start(); }
            if (dragging)
            {
                float track = ClientSize.Height - Thumb().Height;
                if (track > 0) ScrollTo(dragStartOffset + (int)((e.Y - dragStartY) * MaxOffset / track));
            }
        }
        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); if (!dragging) { barTarget = 0; anim.Start(); } }
        protected void PaintBar(Graphics g)
        {
            if (!HasBar) return;
            Theme.Smooth(g);
            RectangleF t = Thumb();
            using (GraphicsPath p = Theme.Round(t, t.Width / 2f)) using (SolidBrush b = new SolidBrush(Theme.Alpha(Theme.OnSurfaceVariant, 0.35f + 0.3f * barHover))) g.FillPath(b, p);
        }
        protected override void OnPaintBackground(PaintEventArgs e) { using (SolidBrush b = new SolidBrush(Theme.BackOf(this))) e.Graphics.FillRectangle(b, ClientRectangle); }
        protected override void Dispose(bool disposing) { if (disposing) anim.Dispose(); base.Dispose(disposing); }
    }

    // ------------------------------------------------------------------ list with check boxes / single selection
    public class WdlList : WdlScrollable
    {
        public bool CheckBoxes = true;
        readonly List<WdlItem> items = new List<WdlItem>();
        int hot = -1, selected = -1, rowH;
        readonly ToolTip tip = new ToolTip();
        int tipIndex = -1;
        public event EventHandler<ItemCheckingEventArgs> ItemChecking;
        public event EventHandler ItemCheckedChanged;
        public event EventHandler SelectedIndexChanged;

        public WdlList() { rowH = Theme.S(58); }
        public override void ApplyTheme()
        {
            base.ApplyTheme();
            Font = Theme.Font(TextStyle.Body);
            rowH = Math.Max(Theme.S(54), TextRenderer.MeasureText("Ag", Theme.Font(TextStyle.Body)).Height + TextRenderer.MeasureText("Ag", Theme.Font(TextStyle.Caption)).Height + Theme.S(22));
            ScrollTo(offset);
        }
        protected override int ContentHeight { get { return items.Count * rowH + Theme.S(4); } }
        public int Count { get { return items.Count; } }
        public WdlItem Item(int i) { return items[i]; }
        public void SetItems(WdlItem[] list)
        {
            items.Clear(); items.AddRange(list); offset = 0; hot = -1;
            selected = (!CheckBoxes && items.Count > 0) ? 0 : -1;
            Invalidate();
        }
        public int SelectedIndex
        {
            get { return selected; }
            set { int v = Math.Max(-1, Math.Min(items.Count - 1, value)); if (v != selected) { selected = v; EnsureVisible(v); Invalidate(); if (SelectedIndexChanged != null) SelectedIndexChanged(this, EventArgs.Empty); } }
        }
        public WdlItem SelectedItem { get { return selected >= 0 && selected < items.Count ? items[selected] : null; } }
        public bool GetItemChecked(int i) { return items[i].Checked; }
        public void SetItemChecked(int i, bool v) { items[i].Checked = v; Invalidate(); }
        public int[] CheckedIndices { get { List<int> l = new List<int>(); for (int i = 0; i < items.Count; i++) if (items[i].Checked) l.Add(i); return l.ToArray(); } }
        void EnsureVisible(int i)
        {
            if (i < 0) return;
            int top = i * rowH, bottom = top + rowH;
            if (top < offset) ScrollTo(top); else if (bottom > offset + ClientSize.Height) ScrollTo(bottom - ClientSize.Height);
        }
        int IndexAt(Point p) { if (OverBar(p)) return -1; int i = (p.Y + offset - Theme.S(2)) / rowH; return (i >= 0 && i < items.Count && p.Y + offset >= Theme.S(2)) ? i : -1; }
        void Toggle(int i)
        {
            if (!CheckBoxes || i < 0 || i >= items.Count || !Enabled) return;
            ItemCheckingEventArgs a = new ItemCheckingEventArgs(); a.Index = i; a.NewValue = !items[i].Checked;
            if (ItemChecking != null) ItemChecking(this, a);
            if (a.Cancel || a.NewValue == items[i].Checked) return;
            items[i].Checked = a.NewValue; Invalidate();
            if (ItemCheckedChanged != null) ItemCheckedChanged(this, EventArgs.Empty);
        }
        protected override void OnMouseClick(MouseEventArgs e)
        {
            base.OnMouseClick(e);
            int i = IndexAt(e.Location); if (i < 0) return;
            SelectedIndex = i; Toggle(i);
        }
        protected override bool IsInputKey(Keys k) { return k == Keys.Up || k == Keys.Down || k == Keys.Space || base.IsInputKey(k); }
        protected override void OnKeyDown(KeyEventArgs e)
        {
            base.OnKeyDown(e);
            if (e.KeyCode == Keys.Down) SelectedIndex = selected + 1;
            else if (e.KeyCode == Keys.Up) SelectedIndex = Math.Max(0, selected - 1);
            else if (e.KeyCode == Keys.Space) Toggle(selected);
        }
        protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); if (selected < 0 && items.Count > 0 && CheckBoxes) selected = 0; Invalidate(); }
        protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }
        protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); Invalidate(); }
        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            int i = IndexAt(e.Location);
            if (i != hot) { hot = i; Invalidate(); }
            Cursor = i >= 0 ? Cursors.Hand : Cursors.Default;
            if (i != tipIndex)
            {
                tipIndex = i;
                string t = i >= 0 ? items[i].Tooltip : "";
                tip.SetToolTip(this, string.IsNullOrEmpty(t) ? null : t);
            }
        }
        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); hot = -1; Invalidate(); }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            Theme.Smooth(g);
            int first = Math.Max(0, offset / rowH), last = Math.Min(items.Count - 1, (offset + ClientSize.Height) / rowH + 1);
            int barSpace = HasBar ? BarWidth : 0;
            for (int i = first; i <= last; i++) DrawRow(g, i, new Rectangle(0, Theme.S(2) + i * rowH - offset, ClientSize.Width - barSpace, rowH));
            PaintBar(g);
        }
        void DrawRow(Graphics g, int index, Rectangle b)
        {
            WdlItem it = items[index];
            Color back = Theme.BackOf(this);
            bool sel = !CheckBoxes && index == selected;
            RectangleF row = new RectangleF(b.X + Theme.SF(2), b.Y + Theme.SF(2), b.Width - Theme.SF(4), b.Height - Theme.SF(4));
            Color fill = Color.Empty;
            if (sel) fill = Theme.SecondaryContainer;
            else if (CheckBoxes && it.Checked) fill = Theme.Mix(back, Theme.PrimaryContainer, Theme.Dark ? 0.45f : 0.6f);
            if (index == hot && Enabled) fill = Theme.Mix(fill == Color.Empty ? back : fill, Theme.OnSurface, 0.06f);
            if (fill != Color.Empty) using (GraphicsPath p = Theme.Round(row, Theme.SF(16))) using (SolidBrush br = new SolidBrush(fill)) g.FillPath(br, p);
            if (CheckBoxes && index == selected && Focused)
                using (GraphicsPath p = Theme.Round(row, Theme.SF(16))) using (Pen pen = new Pen(Theme.Primary, Theme.SF(1.5f))) g.DrawPath(pen, p);
            float x = row.X + Theme.SF(14);
            float a = Enabled ? 1f : 0.38f;
            if (CheckBoxes)
            {
                RectangleF br = new RectangleF(x, row.Y + (row.Height - Theme.SF(18)) / 2f, Theme.SF(18), Theme.SF(18));
                using (GraphicsPath p = Theme.Round(br, Theme.SF(4)))
                {
                    if (it.Checked) { using (SolidBrush bb = new SolidBrush(Theme.Alpha(Theme.Primary, a))) g.FillPath(bb, p); Theme.DrawGlyph(g, Glyph.Check, br, Theme.OnPrimary); }
                    else using (Pen pen = new Pen(Theme.Alpha(Theme.OnSurfaceVariant, a), Theme.SF(2))) g.DrawPath(pen, p);
                }
                x += Theme.SF(34);
            }
            int badgeW = 0;
            Font cap = Theme.Font(TextStyle.Caption);
            if (!string.IsNullOrEmpty(it.Badge))
            {
                Size bs = TextRenderer.MeasureText(it.Badge, cap, Size.Empty, TextFormatFlags.NoPadding);
                badgeW = bs.Width + Theme.S(20);
                RectangleF chip = new RectangleF(row.Right - badgeW - Theme.SF(10), row.Y + (row.Height - Theme.SF(24)) / 2f, badgeW, Theme.SF(24));
                Color cbg = it.Warn ? Theme.TertiaryContainer : Theme.SecondaryContainer, cfg = it.Warn ? Theme.OnTertiaryContainer : Theme.OnSecondaryContainer;
                using (GraphicsPath p = Theme.Round(chip, Theme.SF(8))) using (SolidBrush cb = new SolidBrush(cbg)) g.FillPath(cb, p);
                TextRenderer.DrawText(g, it.Badge, cap, Rectangle.Round(chip), cfg, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
                badgeW += Theme.S(16);
            }
            int tw = (int)(row.Right - x - badgeW - Theme.SF(8));
            Font body = Theme.Font(TextStyle.Body);
            int h1 = TextRenderer.MeasureText("Ag", body).Height, h2 = string.IsNullOrEmpty(it.Subtitle) ? 0 : TextRenderer.MeasureText("Ag", cap).Height;
            float ty = row.Y + (row.Height - h1 - h2) / 2f;
            TextRenderer.DrawText(g, it.Title, body, new Rectangle((int)x, (int)ty, tw, h1), Theme.Alpha(sel ? Theme.OnSecondaryContainer : Theme.OnSurface, a), TextFormatFlags.NoPadding | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine);
            if (h2 > 0) TextRenderer.DrawText(g, it.Subtitle, cap, new Rectangle((int)x, (int)ty + h1, tw, h2), Theme.Alpha(Theme.OnSurfaceVariant, a), TextFormatFlags.NoPadding | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine);
        }
        protected override void Dispose(bool disposing) { if (disposing) tip.Dispose(); base.Dispose(disposing); }
    }

    // ------------------------------------------------------------------ read-only text (log, preview): wraps, themed scroll bar, copy
    public class WdlTextView : WdlScrollable
    {
        readonly List<string> lines = new List<string>();
        readonly List<string> wrapped = new List<string>();
        int lineH = 16, wrapCols = -1;
        public bool Mono = true;
        public WdlTextView()
        {
            ContextMenuStrip m = new ContextMenuStrip();
            m.Items.Add("Copy", null, delegate { CopyAll(); });
            ContextMenuStrip = m;
        }
        public override void ApplyTheme() { base.ApplyTheme(); Font = Theme.Font(Mono ? TextStyle.Mono : TextStyle.Body); lineH = TextRenderer.MeasureText("Ag", Font).Height + Theme.S(2); wrapCols = -1; Rewrap(); }
        public void CopyAll() { try { if (lines.Count > 0) Clipboard.SetText(string.Join(Environment.NewLine, lines.ToArray())); } catch (Exception) { } }
        public override string Text
        {
            get { return string.Join(Environment.NewLine, lines.ToArray()); }
            set { lines.Clear(); if (!string.IsNullOrEmpty(value)) lines.AddRange(value.Replace("\r\n", "\n").Split('\n')); wrapCols = -1; Rewrap(); offset = 0; Invalidate(); }
        }
        public void AppendText(string s)
        {
            bool atEnd = offset >= MaxOffset - lineH;
            foreach (string l in s.Replace("\r\n", "\n").TrimEnd('\n').Split('\n')) { lines.Add(l); WrapLine(l); }
            if (lines.Count > 5000) { lines.RemoveRange(0, lines.Count - 4000); wrapCols = -1; Rewrap(); }
            if (atEnd) ScrollToEnd();
            Invalidate();
        }
        protected override int ContentHeight { get { return wrapped.Count * lineH + Theme.S(8); } }
        int Cols()
        {
            int cw = Math.Max(1, TextRenderer.MeasureText(new string('M', 20), Font, Size.Empty, TextFormatFlags.NoPadding).Width / 20);
            return Math.Max(20, (ClientSize.Width - BarWidth - Theme.S(4)) / cw);
        }
        void WrapLine(string l)
        {
            int c = Math.Max(20, wrapCols);
            if (l.Length <= c) { wrapped.Add(l); return; }
            for (int i = 0; i < l.Length; i += c) wrapped.Add((i == 0 ? "" : "    ") + l.Substring(i, Math.Min(c, l.Length - i)));
        }
        void Rewrap()
        {
            int c = Cols();
            if (c == wrapCols) return;
            wrapCols = c; wrapped.Clear();
            foreach (string l in lines) WrapLine(l);
            ScrollTo(offset);
        }
        protected override void OnResize(EventArgs e) { Rewrap(); base.OnResize(e); }
        protected override void OnKeyDown(KeyEventArgs e)
        {
            base.OnKeyDown(e);
            if (e.Control && (e.KeyCode == Keys.C || e.KeyCode == Keys.A)) CopyAll();
            if (e.KeyCode == Keys.PageDown) ScrollTo(offset + ClientSize.Height);
            if (e.KeyCode == Keys.PageUp) ScrollTo(offset - ClientSize.Height);
            if (e.KeyCode == Keys.Down) ScrollTo(offset + lineH);
            if (e.KeyCode == Keys.Up) ScrollTo(offset - lineH);
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            int first = Math.Max(0, offset / lineH), last = Math.Min(wrapped.Count - 1, (offset + ClientSize.Height) / lineH + 1);
            for (int i = first; i <= last; i++)
            {
                string l = wrapped[i];
                Color c = Theme.OnSurface;
                if (l.Contains("[WARN]") || l.Contains("FAILED")) c = Theme.Tertiary;
                else if (l.Contains("[ERROR]")) c = Theme.Error;
                else if (l.Contains("[OK]")) c = Theme.Primary;
                else if (l.Contains("[SKIP]") || l.StartsWith("    ")) c = Theme.OnSurfaceVariant;
                TextRenderer.DrawText(g, l, Font, new Point(Theme.S(2), Theme.S(4) + i * lineH - offset), c, TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
            }
            PaintBar(g);
        }
    }

    // ------------------------------------------------------------------ dropdown (pill field + themed menu)
    public class WdlDropdown : Control, IThemed
    {
        public readonly List<string> Items = new List<string>();
        int selected = -1;
        float hover, hoverTarget;
        bool open;
        readonly Timer anim = new Timer();
        public event EventHandler SelectedIndexChanged;
        public WdlDropdown()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.UserPaint | ControlStyles.Selectable | ControlStyles.StandardClick, true);
            Cursor = Cursors.Hand; TabStop = true; Height = Theme.S(40);
            anim.Interval = 15;
            anim.Tick += delegate { hover += (hoverTarget - hover) * 0.3f; if (Math.Abs(hover - hoverTarget) < 0.02f) { hover = hoverTarget; anim.Stop(); } Invalidate(); };
        }
        public int SelectedIndex
        {
            get { return selected; }
            set { int v = Math.Max(-1, Math.Min(Items.Count - 1, value)); if (v != selected) { selected = v; Invalidate(); if (SelectedIndexChanged != null) SelectedIndexChanged(this, EventArgs.Empty); } }
        }
        public void SetItems(string[] list) { Items.Clear(); Items.AddRange(list); selected = Items.Count > 0 ? 0 : -1; Invalidate(); }
        // replaces item texts (language switch) without raising SelectedIndexChanged
        public void SetTexts(string[] list) { int s = selected; Items.Clear(); Items.AddRange(list); selected = Math.Min(s, Items.Count - 1); Invalidate(); }
        public void ApplyTheme() { Font = Theme.Font(TextStyle.Body); Height = Theme.S(40); Invalidate(); }
        protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); hoverTarget = 1; anim.Start(); }
        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); hoverTarget = 0; anim.Start(); }
        protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
        protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }
        protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); Invalidate(); }
        protected override bool IsInputKey(Keys k) { return k == Keys.Up || k == Keys.Down || base.IsInputKey(k); }
        protected override void OnKeyDown(KeyEventArgs e)
        {
            base.OnKeyDown(e);
            if (e.KeyCode == Keys.Down) SelectedIndex = Math.Min(Items.Count - 1, selected + 1);
            if (e.KeyCode == Keys.Up) SelectedIndex = Math.Max(0, selected - 1);
            if (e.KeyCode == Keys.Space || e.KeyCode == Keys.Enter || (e.Alt && e.KeyCode == Keys.Down)) ShowMenu();
        }
        protected override void OnClick(EventArgs e) { base.OnClick(e); ShowMenu(); }
        void ShowMenu()
        {
            if (!Enabled || Items.Count == 0) return;
            ContextMenuStrip m = new ContextMenuStrip();
            m.Renderer = new MenuRenderer(); m.Font = Font; m.ShowImageMargin = false; m.BackColor = Theme.CardHigh; m.Padding = new Padding(0, Theme.S(6), 0, Theme.S(6));
            for (int i = 0; i < Items.Count; i++)
            {
                int idx = i;
                ToolStripMenuItem it = new ToolStripMenuItem(Items[i]);
                it.ForeColor = Theme.OnSurface; it.Padding = new Padding(Theme.S(8), Theme.S(8), Theme.S(8), Theme.S(8));
                it.Font = i == selected ? Theme.Font(TextStyle.BodyStrong) : Font;
                it.Click += delegate { SelectedIndex = idx; };
                m.Items.Add(it);
            }
            m.MinimumSize = new Size(Width, 0);
            m.Closed += delegate { open = false; Invalidate(); m.Dispose(); };
            open = true; Invalidate();
            m.Show(this, new Point(0, Height + Theme.S(4)));
        }
        protected override void OnPaintBackground(PaintEventArgs e) { using (SolidBrush b = new SolidBrush(Theme.BackOf(Parent))) e.Graphics.FillRectangle(b, ClientRectangle); }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            Theme.Smooth(g);
            float a = Enabled ? 1f : 0.38f;
            RectangleF r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
            using (GraphicsPath p = Theme.Round(r, Theme.SF(12)))
            {
                using (SolidBrush b = new SolidBrush(Theme.Mix(Theme.CardHigh, Theme.OnSurface, Enabled ? 0.05f * hover : 0f))) g.FillPath(b, p);
                Color oc = (open || Focused) ? Theme.Primary : Theme.Mix(Theme.OutlineVariant, Theme.Outline, hover);
                using (Pen pen = new Pen(Theme.Alpha(oc, a), Theme.SF(open || Focused ? 2f : 1f))) g.DrawPath(pen, p);
            }
            string t = selected >= 0 && selected < Items.Count ? Items[selected] : "";
            TextRenderer.DrawText(g, t, Font, new Rectangle(Theme.S(14), 0, Width - Theme.S(44), Height), Theme.Alpha(Theme.OnSurface, a), TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
            float cx = Width - Theme.SF(22), cy = Height / 2f, s = Theme.SF(4.5f);
            using (Pen pen = new Pen(Theme.Alpha(Theme.OnSurfaceVariant, a), Theme.SF(2))) { pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round; pen.LineJoin = LineJoin.Round;
                if (open) g.DrawLines(pen, new PointF[] { new PointF(cx - s, cy + s / 2), new PointF(cx, cy - s / 2), new PointF(cx + s, cy + s / 2) });
                else g.DrawLines(pen, new PointF[] { new PointF(cx - s, cy - s / 2), new PointF(cx, cy + s / 2), new PointF(cx + s, cy - s / 2) }); }
        }
        protected override void Dispose(bool disposing) { if (disposing) anim.Dispose(); base.Dispose(disposing); }
    }

    public class MenuRenderer : ToolStripProfessionalRenderer
    {
        protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e) { using (SolidBrush b = new SolidBrush(Theme.CardHigh)) e.Graphics.FillRectangle(b, e.AffectedBounds); }
        protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e)
        {
            using (Pen p = new Pen(Theme.OutlineVariant)) e.Graphics.DrawRectangle(p, 0, 0, e.AffectedBounds.Width - 1, e.AffectedBounds.Height - 1);
        }
        protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e)
        {
            if (!e.Item.Selected) return;
            Theme.Smooth(e.Graphics);
            RectangleF r = new RectangleF(Theme.SF(6), 1, e.Item.Width - Theme.SF(12), e.Item.Height - 2);
            using (GraphicsPath p = Theme.Round(r, Theme.SF(10))) using (SolidBrush b = new SolidBrush(Theme.SecondaryContainer)) e.Graphics.FillPath(b, p);
        }
        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) { e.TextColor = e.Item.Selected ? Theme.OnSecondaryContainer : Theme.OnSurface; base.OnRenderItemText(e); }
    }

    // ------------------------------------------------------------------ statistic tile (big number + caption + icon)
    public class WdlStat : Control, IThemed
    {
        public Surface Fill = Surface.PrimaryContainer;
        public ColorRole Role = ColorRole.OnPrimaryContainer;
        public string IconName;
        string value = "–";
        public string CaptionKey;
        public WdlStat()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
        }
        public string Value { get { return value; } set { this.value = value; Fit(); Invalidate(); } }
        public void ApplyTheme() { if (CaptionKey != null) Text = Theme.T(CaptionKey); Fit(); Invalidate(); }
        public override Size GetPreferredSize(Size proposed)
        {
            Size n = TextRenderer.MeasureText(value, Theme.Font(TextStyle.Display), Size.Empty, TextFormatFlags.NoPadding);
            Size c = TextRenderer.MeasureText(Text ?? "", Theme.Font(TextStyle.BodyStrong), Size.Empty, TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
            int w = Math.Max(n.Width, c.Width + Theme.S(26)) + Theme.S(52);
            return new Size(Math.Max(Theme.S(196), w), n.Height + c.Height + Theme.S(46));
        }
        void Fit() { Size = GetPreferredSize(Size.Empty); }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            using (SolidBrush b = new SolidBrush(Theme.BackOf(Parent))) g.FillRectangle(b, ClientRectangle);
            Theme.Smooth(g);
            using (GraphicsPath p = Theme.Round(new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f), Theme.SF(28))) using (SolidBrush b = new SolidBrush(Theme.Fill(Fill))) g.FillPath(b, p);
            Color fg = Theme.Role(Role);
            Font nf = Theme.Font(TextStyle.Display), cf = Theme.Font(TextStyle.BodyStrong);
            Size n = TextRenderer.MeasureText(value, nf, Size.Empty, TextFormatFlags.NoPadding);
            int x = Theme.S(26), y = Theme.S(18);
            TextRenderer.DrawText(g, value, nf, new Point(x, y), fg, TextFormatFlags.NoPadding);
            int ch = TextRenderer.MeasureText("Ag", cf, Size.Empty, TextFormatFlags.NoPadding).Height;
            int cy = y + n.Height + Theme.S(8);
            if (IconName != null) Theme.DrawIcon(g, IconName, new RectangleF(x, cy + (ch - Theme.SF(18)) / 2f, Theme.SF(18), Theme.SF(18)), fg);
            TextRenderer.DrawText(g, Text, cf, new Rectangle(x + Theme.S(26), cy, Width - x - Theme.S(26) - Theme.S(16), ch + 2), fg, TextFormatFlags.NoPadding | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine);
        }
    }


    // ------------------------------------------------------------------ layout helpers
    public static class L
    {
        public static FlowLayoutPanel Flow(bool down, bool wrap)
        {
            FlowLayoutPanel p = new FlowLayoutPanel();
            p.AutoSize = true; p.AutoSizeMode = AutoSizeMode.GrowAndShrink; p.Margin = Padding.Empty; p.Padding = Padding.Empty;
            p.FlowDirection = down ? FlowDirection.TopDown : FlowDirection.LeftToRight; p.WrapContents = wrap;
            return p;
        }
        public static TableLayoutPanel Table(int cols, int rows)
        {
            TableLayoutPanel t = new TableLayoutPanel();
            t.ColumnCount = cols; t.RowCount = rows; t.Margin = Padding.Empty; t.Padding = Padding.Empty;
            return t;
        }
        public static Padding M(float l, float t, float r, float b) { return new Padding(Theme.S(l), Theme.S(t), Theme.S(r), Theme.S(b)); }
        public static Padding M(float all) { return new Padding(Theme.S(all)); }
    }

    // ------------------------------------------------------------------ base window
    public class WdlForm : Form
    {
        public WdlForm()
        {
            AutoScaleMode = AutoScaleMode.None;   // sizes are scaled by Theme.S, fonts by the system DPI
            DoubleBuffered = true;
            StartPosition = FormStartPosition.CenterScreen;
            if (Theme.IconDir != null)
            {
                string ico = Path.Combine(Path.GetDirectoryName(Theme.IconDir), "WinDebloatLive.ico");
                try { if (File.Exists(ico)) Icon = new Icon(ico); } catch (Exception) { }
            }
        }
        protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); Theme.StyleWindow(this); }
        public void ApplyTheme() { Theme.Apply(this); }
        // initial size in dp, kept inside the working area of the screen
        public void FitToScreen(int wDp, int hDp, int minWDp, int minHDp)
        {
            Rectangle wa = Screen.PrimaryScreen.WorkingArea;
            try { wa = Screen.FromPoint(Cursor.Position).WorkingArea; } catch (Exception) { }
            Size = new Size(Math.Min(Theme.S(wDp), (int)(wa.Width * 0.94)), Math.Min(Theme.S(hDp), (int)(wa.Height * 0.94)));
            MinimumSize = new Size(Math.Min(Theme.S(minWDp), wa.Width), Math.Min(Theme.S(minHDp), wa.Height));
        }
    }

    // ------------------------------------------------------------------ main window
    public class MainForm : WdlForm
    {
        public WdlStat statApps, statTweaks, statKept;
        public WdlLabel lblTitle, lblSys, lblSimpleHead, lblSimpleDesc, lblKept, lblAppsTitle, lblTweaksTitle, lblNotOffered, lblPreset, lblStatus, lblLog, lblRules;
        public WdlSegmented segMode;
        public WdlDropdown cbLang, cbPreset;
        public Panel body;
        public Control pnlSimple, pnlAdv;
        public WdlCard cardHero, cardApps, cardTweaks, cardOptions, cardLog;
        public WdlButton btnGo, btnSimplePreview, btnAppDef, btnAppAll, btnAppNone, btnPresetApply, btnPreview, btnApply, btnUndo, btnRescan, btnCancel,
            btnLogToggle, btnLogs, btnBackups;
        public WdlList clbApps, clbTweaks;
        public WdlToggle rbAll, rbCur, chkRestore, chkProtect, chkDefaultUser, chkRules;
        public WdlProgress pb;
        public WdlTextView tbLog;
        public PictureBox picLogo;
        readonly TableLayoutPanel root;
        bool logOpen = true;

        public MainForm()
        {
            Text = "WinDebloat Live";
            FitToScreen(1180, 880, 900, 620);
            root = L.Table(1, 6);
            root.Dock = DockStyle.Fill; root.Padding = L.M(24, 16, 24, 10);
            root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, Theme.S(150)));
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));

            // header: logo, title + system line | mode switch, language
            TableLayoutPanel hdr = L.Table(3, 1);
            hdr.Dock = DockStyle.Fill; hdr.AutoSize = true; hdr.Margin = L.M(0, 0, 0, 14);
            hdr.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            hdr.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            hdr.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            picLogo = new PictureBox(); picLogo.Size = new Size(Theme.S(52), Theme.S(52)); picLogo.SizeMode = PictureBoxSizeMode.Zoom; picLogo.Margin = L.M(0, 0, 14, 0);
                        if (Theme.IconDir != null)
            {
                string png = Path.Combine(Path.GetDirectoryName(Theme.IconDir), "icon-256.png");
                try { if (File.Exists(png)) using (MemoryStream ms = new MemoryStream(File.ReadAllBytes(png))) using (Image i = Image.FromStream(ms)) picLogo.Image = new Bitmap(i); } catch (Exception) { }
            }
            FlowLayoutPanel ht = L.Flow(true, false); ht.Anchor = AnchorStyles.Left;
            lblTitle = new WdlLabel("@hdr.title", TextStyle.Headline, ColorRole.OnSurface);
            lblSys = new WdlLabel("@hdr.scanning", TextStyle.Caption, ColorRole.OnSurfaceVariant); lblSys.Margin = L.M(2, 2, 0, 0);
            ht.Controls.Add(lblTitle); ht.Controls.Add(lblSys);
            FlowLayoutPanel hr = L.Flow(false, false); hr.Anchor = AnchorStyles.Right;
            segMode = new WdlSegmented(); segMode.Keys = new string[] { "mode.simple", "mode.advanced" }; segMode.Margin = L.M(0, 0, 12, 0);
            cbLang = new WdlDropdown(); cbLang.Width = Theme.S(160); cbLang.Margin = L.M(0, 2, 0, 0);
            hr.Controls.Add(segMode); hr.Controls.Add(cbLang);
            hdr.Controls.Add(picLogo, 0, 0); hdr.Controls.Add(ht, 1, 0); hdr.Controls.Add(hr, 2, 0);

            body = new Panel(); body.Dock = DockStyle.Fill; body.Margin = Padding.Empty;
            pnlSimple = BuildSimple(); pnlAdv = BuildAdvanced();
            body.Controls.Add(pnlSimple); body.Controls.Add(pnlAdv);

            // options
            cardOptions = new WdlCard(); cardOptions.Fill = Surface.Card; cardOptions.Radius = 20; cardOptions.Dock = DockStyle.Fill;
            cardOptions.AutoSize = true; cardOptions.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            cardOptions.Padding = L.M(20, 8, 20, 8); cardOptions.Margin = L.M(0, 12, 0, 0);
            FlowLayoutPanel of = L.Flow(false, true); of.Dock = DockStyle.Fill;
            chkRestore = new WdlToggle("@chk.restore", ToggleKind.Switch); chkRestore.Checked = true;
            chkProtect = new WdlToggle("", ToggleKind.Switch);
            chkDefaultUser = new WdlToggle("@chk.defaultUser", ToggleKind.Switch); chkDefaultUser.Checked = true;
            chkRules = new WdlToggle("@chk.rulesUpdate", ToggleKind.Switch);
            foreach (WdlToggle t in new WdlToggle[] { chkRestore, chkProtect, chkDefaultUser, chkRules }) { t.Margin = L.M(0, 2, 28, 2); of.Controls.Add(t); }
            cardOptions.Controls.Add(of);

            // action bar: status + progress | buttons
            TableLayoutPanel act = L.Table(2, 1); act.Dock = DockStyle.Fill; act.AutoSize = true; act.Margin = L.M(0, 14, 0, 0);
            act.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); act.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            TableLayoutPanel st = L.Table(1, 2); st.Dock = DockStyle.Fill; st.AutoSize = true; st.Margin = L.M(4, 0, 24, 0);
            st.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            lblStatus = new WdlLabel("@status.ready", TextStyle.BodyStrong, ColorRole.OnSurface); lblStatus.AutoEllipsis = true; lblStatus.AutoSize = false;
            lblStatus.Dock = DockStyle.Fill; lblStatus.Height = Theme.S(24); lblStatus.TextAlign = ContentAlignment.BottomLeft;
            pb = new WdlProgress(); pb.Dock = DockStyle.Fill; pb.Margin = L.M(0, 4, 0, 0);
            st.Controls.Add(lblStatus, 0, 0); st.Controls.Add(pb, 0, 1);
            FlowLayoutPanel bf = L.Flow(false, false); bf.Anchor = AnchorStyles.Right;
            btnCancel = new WdlButton("@btn.cancel", ButtonKind.Text, "stop"); btnCancel.Destructive = true; btnCancel.Enabled = false;
            btnRescan = new WdlButton("@btn.rescan", ButtonKind.Text, "refresh");
            btnUndo = new WdlButton("@btn.undo", ButtonKind.Outlined, "reset");
            btnPreview = new WdlButton("@btn.preview", ButtonKind.Tonal, "eye");
            btnApply = new WdlButton("@btn.apply", ButtonKind.Filled, "broom");
            foreach (WdlButton b in new WdlButton[] { btnCancel, btnRescan, btnUndo, btnPreview, btnApply }) { b.Margin = L.M(8, 0, 0, 0); bf.Controls.Add(b); }
            act.Controls.Add(st, 0, 0); act.Controls.Add(bf, 1, 0);

            // log
            cardLog = new WdlCard(); cardLog.Fill = Surface.CardHigh; cardLog.Radius = 20; cardLog.Dock = DockStyle.Fill; cardLog.Margin = L.M(0, 12, 0, 0);
            cardLog.Padding = L.M(16, 6, 8, 8);
            TableLayoutPanel lt = L.Table(1, 2); lt.Dock = DockStyle.Fill;
            lt.RowStyles.Add(new RowStyle(SizeType.AutoSize)); lt.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); lt.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            TableLayoutPanel lh = L.Table(2, 1); lh.Dock = DockStyle.Fill; lh.AutoSize = true;
            lh.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); lh.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            lblLog = new WdlLabel("@lbl.log", TextStyle.Label, ColorRole.OnSurfaceVariant); lblLog.Anchor = AnchorStyles.Left;
            btnLogToggle = new WdlButton("@btn.logHide", ButtonKind.Text, null); btnLogToggle.Small = true; btnLogToggle.Anchor = AnchorStyles.Right;
            lh.Controls.Add(lblLog, 0, 0); lh.Controls.Add(btnLogToggle, 1, 0);
            tbLog = new WdlTextView(); tbLog.Dock = DockStyle.Fill; tbLog.Margin = L.M(0, 2, 0, 0);
            lt.Controls.Add(lh, 0, 0); lt.Controls.Add(tbLog, 0, 1);
            cardLog.Controls.Add(lt);
            btnLogToggle.Click += delegate { SetLogOpen(!logOpen); };

            // footer
            FlowLayoutPanel ft = L.Flow(false, true); ft.Dock = DockStyle.Fill; ft.Margin = L.M(0, 6, 0, 0);
            btnLogs = new WdlButton("@lnk.log", ButtonKind.Text, "folder-open"); btnLogs.Small = true;
            btnBackups = new WdlButton("@lnk.backups", ButtonKind.Text, "folder"); btnBackups.Small = true;
            lblRules = new WdlLabel("", TextStyle.Caption, ColorRole.OnSurfaceVariant); lblRules.IconName = "shield-check"; lblRules.Margin = L.M(12, 8, 0, 0);
            ft.Controls.Add(btnLogs); ft.Controls.Add(btnBackups); ft.Controls.Add(lblRules);

            root.Controls.Add(hdr, 0, 0); root.Controls.Add(body, 0, 1); root.Controls.Add(cardOptions, 0, 2);
            root.Controls.Add(act, 0, 3); root.Controls.Add(cardLog, 0, 4); root.Controls.Add(ft, 0, 5);
            Controls.Add(root);
        }

        WdlStat StatTile(Surface s, ColorRole r, string capKey, string icon)
        {
            WdlStat c = new WdlStat(); c.Fill = s; c.Role = r; c.CaptionKey = capKey.Substring(1); c.IconName = icon; c.Margin = L.M(0, 0, 14, 12);
            return c;
        }

        Control BuildSimple()
        {
            cardHero = new WdlCard(); cardHero.Fill = Surface.Card; cardHero.Radius = 32; cardHero.Dock = DockStyle.Fill; cardHero.Padding = L.M(36, 28, 36, 20);
            FlowLayoutPanel f = L.Flow(true, false); f.Dock = DockStyle.Fill; f.AutoSize = false; f.AutoScroll = true;
            lblSimpleHead = new WdlLabel("@simple.head", TextStyle.Headline, ColorRole.OnSurface); lblSimpleHead.Wrap = true;
            lblSimpleDesc = new WdlLabel("@simple.desc", TextStyle.Body, ColorRole.OnSurfaceVariant); lblSimpleDesc.Wrap = true; lblSimpleDesc.Margin = L.M(0, 10, 0, 22);
            FlowLayoutPanel tiles = L.Flow(false, true);
            statApps = StatTile(Surface.PrimaryContainer, ColorRole.OnPrimaryContainer, "@simple.statApps", "package");
            statTweaks = StatTile(Surface.SecondaryContainer, ColorRole.OnSecondaryContainer, "@simple.statTweaks", "sliders");
            statKept = StatTile(Surface.TertiaryContainer, ColorRole.OnTertiaryContainer, "@simple.statKept", "shield-check");
            statKept.Value = "100%";
            tiles.Controls.Add(statApps); tiles.Controls.Add(statTweaks); tiles.Controls.Add(statKept);
            FlowLayoutPanel go = L.Flow(false, true); go.Margin = L.M(0, 16, 0, 0);
            btnGo = new WdlButton("@simple.go", ButtonKind.Filled, "rocket"); btnGo.Large = true;
            btnSimplePreview = new WdlButton("@simple.preview", ButtonKind.Text, "eye"); btnSimplePreview.Large = true; btnSimplePreview.Margin = L.M(12, 0, 0, 0);
            go.Controls.Add(btnGo); go.Controls.Add(btnSimplePreview);
            lblKept = new WdlLabel("@lbl.keptNote", TextStyle.Caption, ColorRole.OnSurfaceVariant); lblKept.Wrap = true; lblKept.Glyph = Glyph.Info; lblKept.Margin = L.M(0, 22, 0, 0);
            f.Controls.Add(lblSimpleHead); f.Controls.Add(lblSimpleDesc); f.Controls.Add(tiles); f.Controls.Add(go); f.Controls.Add(lblKept);
            cardHero.Controls.Add(f);
            return cardHero;
        }

        WdlCard ListCard(out WdlLabel title, out WdlList list, Control bottom, string icon)
        {
            WdlCard c = new WdlCard(); c.Fill = Surface.Card; c.Radius = 28; c.Dock = DockStyle.Fill; c.Padding = L.M(14, 16, 14, 14); c.Margin = L.M(0, 0, 6, 0);
            TableLayoutPanel t = L.Table(1, 3); t.Dock = DockStyle.Fill;
            t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            t.RowStyles.Add(new RowStyle(SizeType.AutoSize)); t.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); t.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            title = new WdlLabel("", TextStyle.Title, ColorRole.OnSurface); title.IconName = icon; title.Margin = L.M(10, 0, 0, 10);
            list = new WdlList(); list.Dock = DockStyle.Fill; list.Margin = Padding.Empty;
            t.Controls.Add(title, 0, 0); t.Controls.Add(list, 0, 1);
            if (bottom != null) t.Controls.Add(bottom, 0, 2);
            c.Controls.Add(t);
            return c;
        }

        Control BuildAdvanced()
        {
            TableLayoutPanel t = L.Table(2, 2); t.Dock = DockStyle.Fill;
            t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 54)); t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 46));
            t.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); t.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            FlowLayoutPanel ab = L.Flow(true, false); ab.Margin = L.M(6, 10, 0, 0);
            FlowLayoutPanel abt = L.Flow(false, false);
            btnAppDef = new WdlButton("@btn.appDef", ButtonKind.Tonal, "reset"); btnAppDef.Small = true;
            btnAppAll = new WdlButton("@btn.appAll", ButtonKind.Tonal, "check-all"); btnAppAll.Small = true;
            btnAppNone = new WdlButton("@btn.appNone", ButtonKind.Tonal, "clear-all"); btnAppNone.Small = true;
            foreach (WdlButton b in new WdlButton[] { btnAppDef, btnAppAll, btnAppNone }) { b.Margin = L.M(0, 0, 8, 6); abt.Controls.Add(b); }
            FlowLayoutPanel sc = L.Flow(true, false);
            rbAll = new WdlToggle("@rb.allUsers", ToggleKind.Radio); rbAll.Margin = L.M(0, 0, 0, 2);
            rbCur = new WdlToggle("@rb.curUser", ToggleKind.Radio);
            sc.Controls.Add(rbAll); sc.Controls.Add(rbCur); rbAll.Checked = true;
            ab.Controls.Add(abt); ab.Controls.Add(sc);
            cardApps = ListCard(out lblAppsTitle, out clbApps, ab, "package");
            lblNotOffered = new WdlLabel("", TextStyle.Caption, ColorRole.OnSurfaceVariant); lblNotOffered.Glyph = Glyph.Info; lblNotOffered.Wrap = true; lblNotOffered.Margin = L.M(8, 10, 0, 0);
            cardTweaks = ListCard(out lblTweaksTitle, out clbTweaks, lblNotOffered, "sliders"); cardTweaks.Margin = L.M(6, 0, 0, 0);
            lblTweaksTitle.Tag = "@grp.tweaks";
            FlowLayoutPanel pr = L.Flow(false, true); pr.Margin = L.M(4, 12, 0, 0);
            lblPreset = new WdlLabel("@lbl.preset", TextStyle.BodyStrong, ColorRole.OnSurface); lblPreset.Margin = L.M(0, 10, 10, 0);
            cbPreset = new WdlDropdown(); cbPreset.Width = Theme.S(360); cbPreset.Margin = L.M(0, 2, 10, 0);
            btnPresetApply = new WdlButton("@btn.presetApply", ButtonKind.Tonal, "sliders");
            pr.Controls.Add(lblPreset); pr.Controls.Add(cbPreset); pr.Controls.Add(btnPresetApply);
            t.Controls.Add(cardApps, 0, 0); t.Controls.Add(cardTweaks, 1, 0); t.Controls.Add(pr, 0, 1); t.SetColumnSpan(pr, 2);
            return t;
        }

        public void SetLogOpen(bool open)
        {
            logOpen = open;
            tbLog.Visible = open;
            root.RowStyles[4] = new RowStyle(SizeType.Absolute, open ? Theme.S(150) : Theme.S(56));
            btnLogToggle.Tag = open ? "@btn.logHide" : "@btn.logShow";
            btnLogToggle.Text = Theme.T(open ? "btn.logHide" : "btn.logShow");
        }
        public bool LogOpen { get { return logOpen; } }

        public void SetMode(bool simple)
        {
            pnlSimple.Visible = simple; pnlAdv.Visible = !simple;
            pnlSimple.Dock = DockStyle.Fill; pnlAdv.Dock = DockStyle.Fill;
            btnPreview.Visible = !simple; btnApply.Visible = !simple; chkDefaultUser.Visible = !simple;
            if (segMode.SelectedIndex != (simple ? 0 : 1)) segMode.SelectedIndex = simple ? 0 : 1;
        }
    }

    // ------------------------------------------------------------------ dialogs
    public class ModeDialog : WdlForm
    {
        public WdlCard cardSimple, cardAdvanced;
        public WdlToggle chkRemember;
        public string Chosen = "";
        FlowLayoutPanel root;
        WdlLabel head;
        readonly List<WdlLabel> titles = new List<WdlLabel>(), descs = new List<WdlLabel>();
        bool sizing;
        const int CardW = 340;
        public ModeDialog()
        {
            FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false;
            Text = "WinDebloat Live";
            root = L.Flow(true, false);
            head = new WdlLabel("@mode.title", TextStyle.Headline, ColorRole.OnSurface); head.Margin = L.M(0, 0, 0, 20);
            FlowLayoutPanel row = L.Flow(false, false);
            cardSimple = Choice("@mode.simple", "@mode.simpleDesc", "rocket", Surface.PrimaryContainer, ColorRole.OnPrimaryContainer, "Simple");
            cardAdvanced = Choice("@mode.advanced", "@mode.advancedDesc", "sliders", Surface.SecondaryContainer, ColorRole.OnSecondaryContainer, "Advanced");
            cardSimple.Margin = Padding.Empty; cardAdvanced.Margin = L.M(16, 0, 0, 0);
            row.Controls.Add(cardSimple); row.Controls.Add(cardAdvanced);
            chkRemember = new WdlToggle("@mode.remember", ToggleKind.Check); chkRemember.Margin = L.M(0, 18, 0, 0);
            root.Controls.Add(head); root.Controls.Add(row); root.Controls.Add(chkRemember);
            Controls.Add(root);
        }
        WdlCard Choice(string title, string desc, string icon, Surface s, ColorRole r, string mode)
        {
            WdlCard c = new WdlCard(); c.Fill = s; c.Radius = 28; c.Clickable = true; c.Padding = L.M(24, 22, 24, 24);
            WdlLabel t = new WdlLabel(title, TextStyle.Title, r); t.IconName = icon; t.Margin = Padding.Empty; t.Location = new Point(c.Padding.Left, c.Padding.Top);
            WdlLabel d = new WdlLabel(desc, TextStyle.Body, r); d.Margin = Padding.Empty;
            c.Controls.Add(t); c.Controls.Add(d);
            titles.Add(t); descs.Add(d);
            c.Click += delegate { Chosen = mode; DialogResult = DialogResult.OK; Close(); };
            return c;
        }
        // both cards share one size: full-width text, height of the taller content
        void Fit()
        {
            if (sizing || root == null) return;
            sizing = true;
            try
            {
                Padding p = cardSimple.Padding;
                int inner = Theme.S(CardW) - p.Horizontal, h = 0;
                for (int i = 0; i < titles.Count; i++)
                {
                    titles[i].MaximumSize = new Size(inner, 0);
                    descs[i].MaximumSize = new Size(inner, 0); descs[i].MinimumSize = new Size(inner, 0);
                    titles[i].Location = new Point(p.Left, p.Top);
                    descs[i].Location = new Point(p.Left, titles[i].Bottom + Theme.S(12));
                    h = Math.Max(h, descs[i].Bottom - p.Top);
                }
                Size cs = new Size(Theme.S(CardW), Math.Max(Theme.S(150), h + p.Vertical));
                cardSimple.Size = cs; cardAdvanced.Size = cs;
                int m = Theme.S(28);
                root.Location = new Point(m, Theme.S(24));
                Size pr = root.GetPreferredSize(Size.Empty);
                ClientSize = new Size(pr.Width + m * 2, pr.Height + Theme.S(24) + Theme.S(22));
            }
            finally { sizing = false; }
        }
        protected override void OnLayout(LayoutEventArgs e) { base.OnLayout(e); Fit(); }
        protected override void OnFontChanged(EventArgs e) { base.OnFontChanged(e); Fit(); }
    }

    public class TextDialog : WdlForm
    {
        public WdlLabel lblHead;
        public WdlTextView tbText;
        public WdlButton btnOk, btnClose;
        public TextDialog()
        {
            FitToScreen(940, 680, 600, 420); ShowInTaskbar = false; StartPosition = FormStartPosition.CenterParent; MinimizeBox = false;
            TableLayoutPanel t = L.Table(1, 3); t.Dock = DockStyle.Fill; t.Padding = L.M(24, 20, 24, 18);
            t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            t.RowStyles.Add(new RowStyle(SizeType.AutoSize)); t.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); t.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            lblHead = new WdlLabel("", TextStyle.Headline, ColorRole.OnSurface); lblHead.Margin = L.M(4, 0, 0, 14);
            WdlCard c = new WdlCard(); c.Fill = Surface.CardHigh; c.Radius = 24; c.Dock = DockStyle.Fill; c.Padding = L.M(18, 14, 8, 14); c.Margin = Padding.Empty;
            tbText = new WdlTextView(); tbText.Dock = DockStyle.Fill;
            c.Controls.Add(tbText);
            FlowLayoutPanel b = L.Flow(false, false); b.Anchor = AnchorStyles.Right; b.Margin = L.M(0, 16, 0, 0);
            btnClose = new WdlButton("@dlg.close", ButtonKind.Outlined, null); btnClose.DialogResult = DialogResult.Cancel;
            btnOk = new WdlButton("", ButtonKind.Filled, "broom"); btnOk.DialogResult = DialogResult.OK; btnOk.Margin = L.M(10, 0, 0, 0);
            b.Controls.Add(btnClose); b.Controls.Add(btnOk);
            t.Controls.Add(lblHead, 0, 0); t.Controls.Add(c, 0, 1); t.Controls.Add(b, 0, 2);
            Controls.Add(t);
            CancelButton = btnClose;
        }
        public void ApplyMono() { tbText.ScrollTo(0); }
    }

    public class UndoDialog : WdlForm
    {
        public WdlLabel lblHead, lblNote;
        public WdlList list;
        public WdlButton btnOk, btnClose, btnRstrui;
        public UndoDialog()
        {
            FitToScreen(760, 560, 560, 400); ShowInTaskbar = false; StartPosition = FormStartPosition.CenterParent; MinimizeBox = false;
            TableLayoutPanel t = L.Table(1, 4); t.Dock = DockStyle.Fill; t.Padding = L.M(24, 20, 24, 18);
            t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            t.RowStyles.Add(new RowStyle(SizeType.AutoSize)); t.RowStyles.Add(new RowStyle(SizeType.AutoSize)); t.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); t.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            lblHead = new WdlLabel("@dlg.undoTitle", TextStyle.Headline, ColorRole.OnSurface); lblHead.Margin = L.M(4, 0, 0, 8);
            lblNote = new WdlLabel("@dlg.undoNote", TextStyle.Caption, ColorRole.OnSurfaceVariant); lblNote.Glyph = Glyph.Info; lblNote.Wrap = true; lblNote.Margin = L.M(4, 0, 0, 14);
            WdlCard c = new WdlCard(); c.Fill = Surface.Card; c.Radius = 24; c.Dock = DockStyle.Fill; c.Padding = L.M(8); c.Margin = Padding.Empty;
            list = new WdlList(); list.CheckBoxes = false; list.Dock = DockStyle.Fill;
            c.Controls.Add(list);
            TableLayoutPanel b = L.Table(2, 1); b.Dock = DockStyle.Fill; b.AutoSize = true; b.Margin = L.M(0, 16, 0, 0);
            b.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); b.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            btnRstrui = new WdlButton("@dlg.rstrui", ButtonKind.Text, "shield-check"); btnRstrui.Anchor = AnchorStyles.Left;
            FlowLayoutPanel r = L.Flow(false, false); r.Anchor = AnchorStyles.Right;
            btnClose = new WdlButton("@dlg.close", ButtonKind.Outlined, null); btnClose.DialogResult = DialogResult.Cancel;
            btnOk = new WdlButton("@dlg.undoRestore", ButtonKind.Filled, "reset"); btnOk.DialogResult = DialogResult.OK; btnOk.Margin = L.M(10, 0, 0, 0);
            r.Controls.Add(btnClose); r.Controls.Add(btnOk);
            b.Controls.Add(btnRstrui, 0, 0); b.Controls.Add(r, 1, 0);
            t.Controls.Add(lblHead, 0, 0); t.Controls.Add(lblNote, 0, 1); t.Controls.Add(c, 0, 2); t.Controls.Add(b, 0, 3);
            Controls.Add(t);
            CancelButton = btnClose;
        }
    }

    // themed replacement for MessageBox: icon in a tonal shape, wrapped text, pill buttons
    public class MessageDialog : WdlForm
    {
        public WdlLabel lblText;
        public MessageDialog(string text, string title, bool yesNo, Glyph glyph)
        {
            FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false; MinimizeBox = false; ShowInTaskbar = false;
            StartPosition = FormStartPosition.CenterParent; AutoSize = true; AutoSizeMode = AutoSizeMode.GrowAndShrink;
            Padding = L.M(26, 24, 28, 20); Text = title;
            TableLayoutPanel t = L.Table(2, 2); t.AutoSize = true;
            Surface s = Surface.SecondaryContainer; ColorRole r = ColorRole.OnSecondaryContainer;
            if (glyph == Glyph.Warning) { s = Surface.TertiaryContainer; r = ColorRole.OnTertiaryContainer; }
            if (glyph == Glyph.Error) { s = Surface.TertiaryContainer; r = ColorRole.Error; }
            GlyphBadge gb = new GlyphBadge(glyph, s, r); gb.Margin = L.M(0, 0, 18, 0);
            lblText = new WdlLabel(text, TextStyle.Body, ColorRole.OnSurface); lblText.MaximumSize = new Size(Theme.S(480), 0); lblText.MinimumSize = new Size(Theme.S(300), 0);
            lblText.Margin = L.M(0, 4, 0, 0);
            FlowLayoutPanel b = L.Flow(false, false); b.Anchor = AnchorStyles.Right; b.Margin = L.M(0, 22, 0, 0);
            if (yesNo)
            {
                WdlButton no = new WdlButton("@dlg.no", ButtonKind.Outlined, null); no.DialogResult = DialogResult.No;
                WdlButton yes = new WdlButton("@dlg.yes", ButtonKind.Filled, null); yes.DialogResult = DialogResult.Yes; yes.Margin = L.M(10, 0, 0, 0);
                b.Controls.Add(no); b.Controls.Add(yes); AcceptButton = yes; CancelButton = no;
            }
            else
            {
                WdlButton ok = new WdlButton("@dlg.ok", ButtonKind.Filled, null); ok.DialogResult = DialogResult.OK; ok.MinimumSize = new Size(Theme.S(96), 0);
                b.Controls.Add(ok); AcceptButton = ok; CancelButton = ok;
            }
            t.Controls.Add(gb, 0, 0); t.Controls.Add(lblText, 1, 0); t.Controls.Add(b, 1, 1);
            Controls.Add(t);
        }
        public static DialogResult Show(IWin32Window owner, string text, string title, bool yesNo, Glyph glyph)
        {
            using (MessageDialog d = new MessageDialog(text, title, yesNo, glyph))
            {
                d.ApplyTheme();
                if (owner == null) d.StartPosition = FormStartPosition.CenterScreen;
                DialogResult r = owner != null ? d.ShowDialog(owner) : d.ShowDialog();
                if (yesNo && r != DialogResult.Yes) r = DialogResult.No;
                return r;
            }
        }
    }

    public class GlyphBadge : Control, IThemed
    {
        readonly Glyph glyph; readonly Surface surface; readonly ColorRole role;
        public GlyphBadge(Glyph g, Surface s, ColorRole r)
        {
            glyph = g; surface = s; role = r;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint, true);
            Size = new Size(Theme.S(48), Theme.S(48));
        }
        public void ApplyTheme() { Invalidate(); }
        protected override void OnPaint(PaintEventArgs e)
        {
            Color c = Theme.BackOf(Parent);
            e.Graphics.Clear(c);
            Theme.Smooth(e.Graphics);
            using (GraphicsPath p = Theme.Round(new RectangleF(0, 0, Width - 1, Height - 1), Theme.SF(16))) using (SolidBrush b = new SolidBrush(Theme.Fill(surface))) e.Graphics.FillPath(b, p);
            float s = Theme.SF(26);
            Theme.DrawGlyph(e.Graphics, glyph, new RectangleF((Width - s) / 2f, (Height - s) / 2f, s, s), Theme.Role(role));
        }
    }
}
