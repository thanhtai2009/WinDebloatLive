// Screenshot harness for the GUI layer (lib\WdlUi.cs): builds the real windows with sample data and saves PNGs.
// Runs under Mono + Xvfb on Linux (tests\tools\render_screens.sh) or under .NET Framework on Windows.
// Usage: Shots.exe <root> <outDir> <shot> <en|vi> <light|dark> <dataDir>
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using WdlUi;

static class Shots
{
    static Dictionary<string, string> Lang(string root, string code)
    {
        Dictionary<string, string> d = new Dictionary<string, string>();
        foreach (string line in File.ReadAllLines(Path.Combine(Path.Combine(root, "lang"), code + ".psd1")))
        {
            Match m = Regex.Match(line, @"^\s*'([^']+)'\s*=\s*'((?:[^']|'')*)'\s*$");
            if (m.Success) d[m.Groups[1].Value] = m.Groups[2].Value.Replace("''", "'").Replace("\\n", "\n");
        }
        return d;
    }

    static Dictionary<string, string> L, En;
    static string T(string k) { string v; if (L.TryGetValue(k, out v)) return v; if (En.TryGetValue(k, out v)) return v; return k; }
    static string T(string k, params object[] a) { return string.Format(T(k), a); }

    static WdlItem[] Items(string file, bool apps)
    {
        List<WdlItem> l = new List<WdlItem>();
        foreach (string line in File.ReadAllLines(file))
        {
            string[] p = line.Split('\t');
            WdlItem it = new WdlItem();
            it.Title = p[0]; it.Subtitle = p[1]; it.Tooltip = p[1]; it.Checked = p[2] == "1";
            if (p[3] == "aggressive") it.Badge = T("lvl.aggressive");
            if (p[3] == "unsafe") { it.Badge = T("app.unsafe"); it.Warn = true; }
            if (p[3] == "optin") { it.Badge = T("app.optIn"); it.Warn = true; }
            l.Add(it);
        }
        return l.ToArray();
    }

    // every button-like control must sit fully inside its window with a margin and be wide enough for its text
    static int layoutBad;
    static void CheckLayout(Form f, Control c, string shot)
    {
        foreach (Control x in c.Controls)
        {
            if (!x.Visible) continue;
            if (x is WdlButton || x is WdlToggle || x is WdlSegmented || x is WdlDropdown || x is GlyphBadge)
            {
                Rectangle r = f.RectangleToClient(x.RectangleToScreen(x.ClientRectangle));
                int m = Theme.S(8);
                Rectangle inner = Rectangle.Inflate(f.ClientRectangle, -m, -m);
                bool inParent = true;
                for (Control p = x.Parent; p != null && p != f; p = p.Parent)
                {
                    if (p is ScrollableControl && ((ScrollableControl)p).AutoScroll) break;
                    Rectangle pr = f.RectangleToClient(p.RectangleToScreen(p.ClientRectangle));
                    if (!pr.Contains(r)) { inParent = false; break; }
                }
                string why = null;
                if (!inner.Contains(r)) why = "closer than " + m + " px to the window edge";
                else if (!inParent) why = "clipped by its container";
                else if (x is WdlButton && x.AutoSize && x.Width < x.GetPreferredSize(Size.Empty).Width) why = "narrower than its text";
                if (why != null) { layoutBad++; Console.WriteLine("layout [" + shot + "] " + x.GetType().Name + " '" + x.Text + "' " + r + ": " + why); }
            }
            CheckLayout(f, x, shot);
        }
    }

    static void Save(Form f, string path)
    {
        f.Show();
        for (int i = 0; i < 30; i++) { Application.DoEvents(); System.Threading.Thread.Sleep(20); }
        if (Environment.GetEnvironmentVariable("WDL_DEBUG") != null) { Console.WriteLine("client " + f.ClientSize + " size " + f.Size); foreach (Control x in f.Controls) Console.WriteLine(" child " + x.Bounds + " pref " + x.GetPreferredSize(Size.Empty)); }
        CheckLayout(f, f, Path.GetFileNameWithoutExtension(path));
        using (Bitmap b = new Bitmap(f.ClientSize.Width, f.ClientSize.Height))
        {
            using (Graphics g = Graphics.FromImage(b))
            {
                Point o = f.PointToScreen(Point.Empty);
                g.CopyFromScreen(o, Point.Empty, f.ClientSize);
            }
            b.Save(path, ImageFormat.Png);
        }
        f.Hide();
        if (layoutBad > 0) Environment.ExitCode = 2;
    }

    // a font that was disposed while a control still holds it throws "Parameter is not valid" on Windows
    static bool Disposed(Font f)
    {
        foreach (string n in new string[] { "nativeFont", "fontObject" })
        {
            System.Reflection.FieldInfo fi = typeof(Font).GetField(n, System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance);
            if (fi != null) return (IntPtr)fi.GetValue(f) == IntPtr.Zero;
        }
        return false;
    }
    static int Bad(Control c)
    {
        int n = Disposed(c.Font) ? 1 : 0;
        foreach (Control x in c.Controls) n += Bad(x);
        return n;
    }
    static bool IsHeader(WdlPreviewList l, int i) { return l.RowKind(i) == 0; }
    static int CountItemsBefore(WdlPreviewList l, int idx) { int n = 0; for (int i = 0; i < idx; i++) if (l.RowKind(i) == 1 && l.HasDetail(i)) n++; return n; }
    static int disposedOpen;
    static ContextMenuStrip MenuOf(WdlDropdown d)
    {
        ContextMenuStrip m = (ContextMenuStrip)typeof(WdlDropdown).GetField("menu", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance).GetValue(d);
        if (m != null && m.Tag == null) { m.Tag = "watched"; m.Disposed += delegate { if (m.Visible) disposedOpen++; }; }
        return m;
    }
    static void Pump() { for (int k = 0; k < 3; k++) Application.DoEvents(); }
    static int Stress()
    {
        MainForm f = new MainForm(); f.ApplyTheme(); f.Show();
        ModeDialog d = new ModeDialog(); d.ApplyTheme(); d.Show();
        int picks = 0;
        EventHandler rebuild = delegate { picks++; f.cbPreset.SetTexts(new string[] { "x", "y" }); f.SetMode(picks % 2 == 0); f.ApplyTheme(); };
        f.cbLang.SelectedIndexChanged += rebuild; f.cbPreset.SelectedIndexChanged += rebuild;
        string[] fams = { null, "DejaVu Sans", "Noto Sans", null };
        int bad = 0;
        for (int i = 0; i < 40; i++)
        {
            Theme.Init(i % 2 == 1, Theme.IconDir);
            Theme.SetFamily(fams[i % fams.Length]);
            WdlDropdown dd = i % 2 == 0 ? f.cbLang : f.cbPreset;
            dd.OpenMenu(); Pump();
            ContextMenuStrip m = MenuOf(dd);
            if (i % 4 < 2 && m != null && m.Items.Count > 1) { m.Items[1].PerformClick(); Pump(); }
            if (i % 4 == 2) f.cbPreset.SetItems(new string[] { "a", "b", "c" });
            f.SetMode(i % 3 == 0);
            f.ApplyTheme(); d.ApplyTheme();
            d.cardSimple.Hover(i % 2 == 0);
            f.Size = new Size(Theme.S(900 + (i % 4) * 100), Theme.S(700 + (i % 3) * 80));
            for (int k = 0; k < 3; k++) Application.DoEvents();
            bad += Bad(f) + Bad(d);
        }
        f.cbLang.OpenMenu(); Pump(); MenuOf(f.cbLang);
        d.Close(); f.Close(); f.Dispose(); d.Dispose(); Pump();
        if (picks == 0) { Console.WriteLine("stress: no dropdown selection was applied"); bad++; }
        if (disposedOpen > 0) { Console.WriteLine("stress: " + disposedOpen + " dropdown menu(s) disposed while visible"); bad += disposedOpen; }
        Console.WriteLine(bad == 0 ? "stress: OK (40 rounds, " + picks + " dropdown picks)" : "stress: " + bad + " control(s) hold a disposed font");
        return bad == 0 ? 0 : 1;
    }

    [STAThread]
    static int Main(string[] a)
    {
        string root = a[0], outDir = a[1], shot = a[2], lang = a[3];
        bool dark = a[4] == "dark";
        L = Lang(root, lang); En = Lang(root, "en");
        Theme.Tr = new Func<string, string>(delegate (string k) { return T(k); });
        Theme.Init(dark, Path.Combine(Path.Combine(root, "assets"), "icons"));
        string sc = Environment.GetEnvironmentVariable("WDL_SCALE");
        float scaleK;
        if (!string.IsNullOrEmpty(sc) && float.TryParse(sc, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out scaleK) && scaleK > 1f) { Theme.Scale = scaleK; Theme.FontScale = scaleK; Theme.SetFamily(null); }
        Application.EnableVisualStyles();
        string file = Path.Combine(outDir, string.Format("{0}_{1}_{2}.png", shot, lang, a[4]));
        string data = a[5];
        if (shot == "mode" || shot == "modehover")
        {
            ModeDialog d = new ModeDialog(); d.ApplyTheme(); if (shot == "modehover") d.cardSimple.Hover(true); Save(d, file); return Environment.ExitCode;
        }
        if (shot == "stress") return Stress();
        if (shot == "msgok")
        {
            MessageDialog d = new MessageDialog(T("msg.noBackups"), "WinDebloat Live", false, Glyph.Info); d.ApplyTheme(); Save(d, file); return Environment.ExitCode;
        }
        if (shot == "message")
        {
            MessageDialog d = new MessageDialog(T("msg.rpConsent", "C:"), "WinDebloat Live", true, Glyph.Warning); d.ApplyTheme(); Save(d, file); return Environment.ExitCode;
        }
        if (shot.StartsWith("preview"))
        {
            TextDialog d = new TextDialog(); d.Text = T("dlg.previewTitle"); d.lblHead.Text = T("dlg.previewTitle"); d.btnOk.Text = T("dlg.applyBtn");
            d.ApplyTheme(); d.btnOk.Text = T("dlg.applyBtn"); d.UsePreview();
            if (shot == "previewbig")
            {
                d.preview.AddSummary("300 items");
                d.preview.AddHeader(T("grp.tweaks"), 300);
                for (int i = 0; i < 300; i++)
                    d.preview.AddItem("Setting " + i, "Plain-language explanation of what setting number " + i + " changes for the user, long enough to wrap on narrow windows.", null,
                        new string[] { @"HKLM\SOFTWARE\Policies\Microsoft\Windows\Very\Long\Path\Segment\Value" + i + ": (not set) -> 1 (DWord)", "Service" + i + ": Manual -> Disabled" });
                d.preview.SetAllOpen(true);
            }
            else
            {
                foreach (string line in File.ReadAllLines(Path.Combine(data, "model_" + lang + ".tsv")))
                {
                    string[] p = line.Split('\t');
                    string[] det = p.Length > 5 && p[5].Length > 0 ? p[5].Split('\u001f') : new string[0];
                    if (p[0] == "Header") d.preview.AddHeader(p[1], int.Parse(p[4]));
                    else if (p[0] == "Summary") d.preview.AddSummary(p[1]);
                    else d.preview.AddItem(p[1], p[2], p[3], det);
                }
            }
            if (shot == "previewset" || shot == "previewopen")
            {
                int idx = -1, seen = 0;
                for (int i = 0; i < d.preview.ItemCount; i++) { if (d.preview.RowTop(i) >= 0 && IsHeader(d.preview, i) && ++seen == 2) { idx = i; break; } }
                if (shot == "previewopen") d.preview.SetOpen(d.preview.FirstItemWithDetail(idx < 0 ? 0 : CountItemsBefore(d.preview, idx) + 1), true);
                d.Show(); Application.DoEvents();
                d.preview.ScrollTo(d.preview.RowTop(idx) - Theme.S(4));
            }
            if (shot == "previewbig")
            {
                d.Show(); Application.DoEvents();
                System.Diagnostics.Stopwatch sw = System.Diagnostics.Stopwatch.StartNew();
                for (int k = 0; k < 40; k++) { d.preview.ScrollTo(k * Theme.S(300)); d.preview.Refresh(); }
                d.Width += Theme.S(40); d.preview.Refresh();
                Console.WriteLine("previewbig: 300 expanded items, 40 scroll repaints + 1 relayout in " + sw.ElapsedMilliseconds + " ms");
                if (sw.ElapsedMilliseconds > 4000) Environment.ExitCode = 3;
            }
            Save(d, file); return Environment.ExitCode;
        }
        if (shot == "undo")
        {
            UndoDialog d = new UndoDialog(); d.Text = T("dlg.undoTitle"); d.ApplyTheme();
            List<WdlItem> l = new List<WdlItem>();
            string[] dates = { "2026-11-03 20:41", "2026-11-02 09:15", "2026-10-28 18:02" };
            int[] n = { 27, 4, 12 };
            for (int i = 0; i < 3; i++)
            {
                WdlItem it = new WdlItem(); it.Title = dates[i]; it.Subtitle = string.Format("{0}: {1}", T("col.changes"), n[i]);
                it.Badge = i == 2 ? T("state.restored") : T("state.active"); it.Warn = i != 2; l.Add(it);
            }
            d.list.SetItems(l.ToArray()); Save(d, file); return Environment.ExitCode;
        }
        MainForm f = new MainForm();
        f.Text = T("app.title", "1.0.0");
        f.cbLang.SetItems(new string[] { "Tiếng Việt", "English", "简体中文", "ភាសាខ្មែរ" });
        f.cbLang.SelectedIndex = lang == "vi" ? 0 : 1;
        f.cbPreset.SetItems(new string[] { T("preset.recommended"), T("preset.aggressive") });
        f.chkProtect.Text = T("chk.protect", "C:");
        f.chkRules.Checked = true;
        WdlItem[] apps = Items(Path.Combine(data, "apps_" + lang + ".tsv"), true);
        WdlItem[] tweaks = Items(Path.Combine(data, "tweaks_" + lang + ".tsv"), false);
        f.clbApps.SetItems(apps); f.clbTweaks.SetItems(tweaks);
        f.lblRules.Text = T("lbl.rulesInfo", "2026.11.1.1", T("rules.bundled"));
        f.ApplyTheme();
        f.lblAppsTitle.Text = T("grp.apps", apps.Length);
        f.lblNotOffered.Text = T("lbl.notOffered", 2);
        f.statApps.Value = "24"; f.statTweaks.Value = "9";
        f.chkProtect.Text = T("chk.protect", "C:");
        f.lblSys.Text = T("hdr.system", "Windows 11 Pro", "24H2", "26100.2314", lang == "vi" ? "PC\\Người Dùng Thử" : "PC\\Test User");
        f.SetMode(shot == "simple");
        f.lblStatus.Text = shot == "simple" ? T("status.ready") : T("status.applying");
        f.pb.Value = shot == "simple" ? 0 : 62;
        f.tbLog.Text = File.ReadAllText(Path.Combine(data, "log_" + lang + ".txt")).Replace("\n", "\r\n");
        if (shot == "simple") f.SetLogOpen(false);
        f.Size = new Size(Theme.S(1180), Theme.S(860));
        Save(f, file);
        return Environment.ExitCode;
    }
}
