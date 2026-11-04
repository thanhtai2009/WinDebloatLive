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

    static void Save(Form f, string path)
    {
        f.Show();
        for (int i = 0; i < 30; i++) { Application.DoEvents(); System.Threading.Thread.Sleep(20); }
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
        Application.EnableVisualStyles();
        string file = Path.Combine(outDir, string.Format("{0}_{1}_{2}.png", shot, lang, a[4]));
        string data = a[5];
        if (shot == "mode" || shot == "modehover")
        {
            ModeDialog d = new ModeDialog(); d.ApplyTheme(); if (shot == "modehover") d.cardSimple.Hover(true); Save(d, file); return 0;
        }
        if (shot == "stress") return Stress();
        if (shot == "message")
        {
            MessageDialog d = new MessageDialog(T("msg.rpConsent", "C:"), "WinDebloat Live", true, Glyph.Warning); d.ApplyTheme(); Save(d, file); return 0;
        }
        if (shot == "preview")
        {
            TextDialog d = new TextDialog(); d.Text = T("dlg.previewTitle"); d.lblHead.Text = T("dlg.previewTitle"); d.btnOk.Text = T("dlg.applyBtn");
            d.tbText.Text = File.ReadAllText(Path.Combine(data, "preview_" + lang + ".txt")).Replace("\n", "\r\n");
            d.ApplyTheme(); d.btnOk.Text = T("dlg.applyBtn"); d.ApplyMono(); Save(d, file); return 0;
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
            d.list.SetItems(l.ToArray()); Save(d, file); return 0;
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
        f.lblSys.Text = T("hdr.system", "Windows 11 Pro", "24H2", "26100.2314", lang == "vi" ? "PC\\Nguyễn Văn Ánh" : "PC\\Alex");
        f.SetMode(shot == "simple");
        f.lblStatus.Text = shot == "simple" ? T("status.ready") : T("status.applying");
        f.pb.Value = shot == "simple" ? 0 : 62;
        f.tbLog.Text = File.ReadAllText(Path.Combine(data, "log_" + lang + ".txt")).Replace("\n", "\r\n");
        if (shot == "simple") f.SetLogOpen(false);
        f.Size = new Size(Theme.S(1180), Theme.S(860));
        Save(f, file);
        return 0;
    }
}
