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
