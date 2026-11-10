// The controls of the Windows tray icon's panel, in the style of Windows 11:
// novacore-tray.ps1 compiles this when it starts, and lays them out from
// `novacore tray menu`. Kept to C# 5, which is what Windows PowerShell 5.1
// compiles, and ASCII-only.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Novacore.Ui {

// Colours, fonts and glyphs in the style of Windows 11, following the
// system's light or dark mode and its accent colour.
public static class Theme {
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr hwnd, string app, string ids);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);

    public static bool Dark;
    public static float Scale = 1f;
    public static Color Back, Footer, Card, Hover, Press, Text, SubText, Disabled, Border, Divider;
    public static Color Accent, OnAccent, ChipFill, ChipHover, ChipBorder, Danger, DangerTint;
    public static Font Body, Strong, Small, SmallStrong, Title, Icons, IconsSmall, Avatar, Underlined;

    public static int S(double n) { return (int) Math.Round(n * Scale); }

    static int Dword(string key, string name, int fallback) {
        try { object v = Registry.GetValue(key, name, null); if (v is int) return (int) v; } catch { }
        return fallback;
    }

    public static bool SystemDark() {
        return Dword(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1) == 0;
    }

    // The accent palette's colour I: 0 is the lightest, 3 the accent itself,
    // 6 the darkest.
    static Color Palette(int i, Color fallback) {
        try {
            byte[] p = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent", "AccentPalette", null) as byte[];
            if (p != null && p.Length >= 32) return Color.FromArgb(p[i * 4], p[i * 4 + 1], p[i * 4 + 2]);
        } catch { }
        return fallback;
    }

    static Color Hex(string s) { return ColorTranslator.FromHtml(s); }

    // A colour T of the way from A to B.
    public static Color Mix(Color a, Color b, double t) {
        return Color.FromArgb((int) (a.R + (b.R - a.R) * t), (int) (a.G + (b.G - a.G) * t), (int) (a.B + (b.B - a.B) * t));
    }

    static Font MakeFont(float size, FontStyle style, params string[] families) {
        foreach (string name in families) {
            Font f = new Font(name, size, style);
            if (string.Equals(f.Name, name, StringComparison.OrdinalIgnoreCase)) return f;
            f.Dispose();
        }
        return new Font(SystemFonts.MessageBoxFont.FontFamily, size, style);
    }

    static bool loaded;

    // (Re)load everything, e.g. after the system switches between light and
    // dark. Returns whether anything changed.
    public static bool Load(float scale) {
        bool dark = SystemDark();
        if (loaded && dark == Dark && scale == Scale) return false;
        loaded = true;
        Dark = dark;
        Scale = scale;
        if (dark) {
            Back = Hex("#2C2C2C"); Footer = Hex("#202020"); Card = Hex("#343434");
            Hover = Hex("#383838"); Press = Hex("#323232");
            Text = Hex("#FFFFFF"); SubText = Hex("#C8C8C8"); Disabled = Hex("#787878");
            Border = Hex("#454545"); Divider = Hex("#3D3D3D");
            ChipFill = Hex("#3A3A3A"); ChipHover = Hex("#434343"); ChipBorder = Hex("#474747");
            Accent = Palette(1, Hex("#60CDFF")); OnAccent = Hex("#000000");
            Danger = Hex("#FF99A4"); DangerTint = Hex("#442726");
        } else {
            Back = Hex("#F9F9F9"); Footer = Hex("#EEEEEE"); Card = Hex("#F0F0F0");
            Hover = Hex("#EDEDED"); Press = Hex("#E6E6E6");
            Text = Hex("#1B1B1B"); SubText = Hex("#5E5E5E"); Disabled = Hex("#A0A0A0");
            Border = Hex("#D6D6D6"); Divider = Hex("#E3E3E3");
            ChipFill = Hex("#FFFFFF"); ChipHover = Hex("#F6F6F6"); ChipBorder = Hex("#DCDCDC");
            Accent = Palette(4, Hex("#005FB8")); OnAccent = Hex("#FFFFFF");
            Danger = Hex("#C42B1C"); DangerTint = Hex("#FDE7E9");
        }
        string[] text = { "Segoe UI Variable Text", "Segoe UI" };
        string[] semibold = { "Segoe UI Variable Text Semibold", "Segoe UI Semibold" };
        string[] display = { "Segoe UI Variable Display Semibold", "Segoe UI Semibold" };
        string[] icons = { "Segoe Fluent Icons", "Segoe MDL2 Assets" };
        Body = MakeFont(10f, FontStyle.Regular, text);
        Underlined = new Font(Body, FontStyle.Underline);
        Strong = MakeFont(10f, FontStyle.Regular, semibold);
        Small = MakeFont(8.5f, FontStyle.Regular, text);
        SmallStrong = MakeFont(8.5f, FontStyle.Regular, semibold);
        Title = MakeFont(13f, FontStyle.Regular, display);
        Avatar = MakeFont(10f, FontStyle.Regular, semibold);
        Icons = MakeFont(12f, FontStyle.Regular, icons);
        IconsSmall = MakeFont(10f, FontStyle.Regular, icons);
        return true;
    }

    // Segoe Fluent Icons' glyph for one of tray/PROTOCOL.md's icon names.
    public static string Glyph(string name) {
        switch (name) {
            case "dashboard": return "\uE80F";  // Home
            case "site":      return "\uE774";  // Globe
            case "open":      return "\uE8A7";  // OpenInNewWindow
            case "git":       return "\uE943";  // Code
            case "info":      return "\uE946";  // Info
            case "folder":    return "\uE8B7";  // Folder
            case "code":      return "\uE70F";  // Edit
            case "terminal":  return "\uE756";  // CommandPrompt
            case "log":       return "\uE9F9";  // ReportDocument
            case "remove":    return "\uE74D";  // Delete
            case "add":       return "\uE710";  // Add
            case "start":     return "\uE768";  // Play
            case "stop":      return "\uE71A";  // Stop
            case "restart":   return "\uE72C";  // Refresh
            case "bug":       return "\uEBE8";  // Bug
            case "tools":     return "\uE90F";  // Repair
            case "database":  return "\uEE94";  // Database
            case "output":    return "\uE756";  // CommandPrompt
            case "refresh":   return "\uE72C";  // Refresh
            case "quit":      return "\uE7E8";  // PowerButton
            case "busy":      return "\uE895";  // Sync
            case "error":     return "\uEA39";  // ErrorBadge
            case "check":     return "\uE73E";  // CheckMark
            case "down":      return "\uE70D";  // ChevronDown
            case "up":        return "\uE70E";  // ChevronUp
            case "right":     return "\uE76C";  // ChevronRight
            default:          return "";
        }
    }

    public static Color StatusColor(string state) {
        switch (state) {
            case "Running": return Dark ? Hex("#6CCB5F") : Hex("#0F7B0F");
            case "Busy":    return Dark ? Hex("#FCE100") : Hex("#9D5D00");
            case "Error":   return Danger;
            default:        return Dark ? Hex("#9A9A9A") : Hex("#8A8A8A");
        }
    }

    static readonly string[] avatarColors = {
        "#0078D4", "#8764B8", "#038387", "#CA5010", "#498205",
        "#C239B3", "#4F6BED", "#DA3B01", "#00B294", "#E3008C" };

    // A colour for NAME's avatar, the same each time.
    public static Color AvatarColor(string name) {
        int h = 0;
        foreach (char c in name ?? "") h = unchecked(h * 31 + c);
        return Hex(avatarColors[(h & 0x7FFFFFFF) % avatarColors.Length]);
    }

    // One or two letters for NAME's avatar: blog -> B, my-site -> MS.
    public static string Initials(string name) {
        string[] parts = (name ?? "").Split(new char[] { '-', '_', '.', ' ' }, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0) return "?";
        string s = parts[0].Substring(0, 1);
        if (parts.Length > 1) s += parts[1].Substring(0, 1);
        return s.ToUpperInvariant();
    }

    public static GraphicsPath Round(Rectangle r, int radius) {
        GraphicsPath path = new GraphicsPath();
        int d = Math.Max(1, Math.Min(radius * 2, Math.Min(r.Width, r.Height)));
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    public static void FillRound(Graphics g, Color c, Rectangle r, int radius) {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (GraphicsPath p = Round(r, radius)) using (SolidBrush b = new SolidBrush(c)) g.FillPath(b, p);
    }

    public static void DrawRound(Graphics g, Color c, Rectangle r, int radius) {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (GraphicsPath p = Round(r, radius)) using (Pen pen = new Pen(c)) g.DrawPath(pen, p);
    }

    public static void Draw(Graphics g, string text, Font font, Color color, Rectangle r, TextFormatFlags flags) {
        TextRenderer.DrawText(g, text, font, r, color, flags | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding);
    }

    // Glyphs, centred in R.
    public static void Glyph(Graphics g, string glyph, Font font, Color color, Rectangle r) {
        Draw(g, glyph, font, color, r, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
    }

    public static int Measure(string text, Font font) {
        return TextRenderer.MeasureText(text ?? "", font, Size.Empty, TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding | TextFormatFlags.SingleLine).Width;
    }

    // Windows 11's rounded corners for a window: small ones for a menu.
    public static void RoundCorners(IntPtr hwnd, bool small) {
        try { int v = small ? 3 : 2; DwmSetWindowAttribute(hwnd, 33, ref v, 4); } catch { }
    }

    public static void BorderColor(IntPtr hwnd, Color c) {
        try { int v = c.R | (c.G << 8) | (c.B << 16); DwmSetWindowAttribute(hwnd, 34, ref v, 4); } catch { }
    }

    // Scroll bars to match the theme.
    public static void ThemeScrollBars(Control c) {
        try { SetWindowTheme(c.Handle, Dark ? "DarkMode_Explorer" : "Explorer", null); } catch { }
    }

    static void RoundMenu(object sender, EventArgs e) { RoundCorners(((Control) sender).Handle, true); }

    // Give MENU, and its submenus as they open, the theme.
    public static void StyleMenu(ToolStripDropDown menu) {
        menu.Renderer = new MenuRenderer();
        menu.Font = Body;
        menu.Padding = new Padding(0, S(4), 0, S(4));
        menu.HandleCreated -= RoundMenu;
        menu.HandleCreated += RoundMenu;
        if (menu.IsHandleCreated) RoundCorners(menu.Handle, true);
        foreach (ToolStripItem item in menu.Items) {
            item.Font = item.Font.Bold ? Strong : Body;
            ToolStripMenuItem mi = item as ToolStripMenuItem;
            if (mi == null) continue;
            mi.Padding = new Padding(0, S(5), 0, S(5));
            if (mi.HasDropDownItems) StyleMenu(mi.DropDown);
        }
    }
}

public class MenuRenderer : ToolStripProfessionalRenderer {
    public MenuRenderer() { RoundedEdges = false; }

    protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e) {
        e.Graphics.Clear(Theme.Back);
    }

    protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e) {
        using (Pen p = new Pen(Theme.Border))
            e.Graphics.DrawRectangle(p, 0, 0, e.ToolStrip.Width - 1, e.ToolStrip.Height - 1);
    }

    protected override void OnRenderImageMargin(ToolStripRenderEventArgs e) { }

    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e) {
        if (!e.Item.Selected || !e.Item.Enabled) return;
        Theme.FillRound(e.Graphics, Theme.Hover, new Rectangle(Theme.S(4), 0, e.Item.Width - Theme.S(8), e.Item.Height), Theme.S(4));
    }

    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
        e.TextColor = e.Item.Enabled ? Theme.Text : Theme.Disabled;
        base.OnRenderItemText(e);
    }

    protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e) {
        int y = e.Item.Height / 2;
        using (Pen p = new Pen(Theme.Divider))
            e.Graphics.DrawLine(p, Theme.S(12), y, e.Item.Width - Theme.S(12), y);
    }

    protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e) {
        Theme.Glyph(e.Graphics, Theme.Glyph("check"), Theme.IconsSmall, e.Item.Enabled ? Theme.Accent : Theme.Disabled, e.ImageRectangle);
    }

    protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e) {
        e.ArrowColor = e.Item.Enabled ? Theme.SubText : Theme.Disabled;
        base.OnRenderArrow(e);
    }
}

public class TagEventArgs : EventArgs {
    public object Tag;
    public TagEventArgs(object tag) { Tag = tag; }
}

// A control that paints itself and knows when the mouse is over it.
public class Widget : Control {
    protected bool hot, down;
    protected static readonly ToolTip tips = new ToolTip();

    public Widget() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
            ControlStyles.UserPaint | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        SetStyle(ControlStyles.Selectable, false);
        BackColor = Color.Transparent;
        Margin = Padding.Empty;
    }

    protected override void OnMouseEnter(EventArgs e) { hot = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hot = false; down = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { down = true; Invalidate(); } base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }

    protected override void OnPaintBackground(PaintEventArgs e) {
        Color c = Parent != null ? Parent.BackColor : Theme.Back;
        e.Graphics.Clear(c);
    }

    protected override void OnClick(EventArgs e) { if (Enabled) base.OnClick(e); }

    // Scroll the nearest Stack that scrolls.
    protected override void OnMouseWheel(MouseEventArgs e) {
        base.OnMouseWheel(e);
        for (Control c = Parent; c != null; c = c.Parent) {
            Stack s = c as Stack;
            if (s != null && s.AutoScroll) { s.Wheel(e.Delta); return; }
        }
    }
}

public class RowButton {
    public string Glyph, Tip;
    public object Tag;
    public bool Enabled = true;
    internal Rectangle Bounds;
}

// A line of the panel: an icon or avatar, a title with details under it,
// buttons for quick actions, and a chevron if it expands.
public class Row : Widget {
    public string Icon, Avatar, Title, Detail;
    public Color AvatarColor, IconColor = Color.Empty;
    public bool Strong, Chevron, Expanded;
    public readonly List<RowButton> Buttons = new List<RowButton>();
    public event EventHandler<TagEventArgs> ButtonClick;
    int hotButton = -1;

    public override Size GetPreferredSize(Size proposed) {
        return new Size(proposed.Width, Theme.S(string.IsNullOrEmpty(Detail) ? 40 : 50));
    }

    void LayoutButtons() {
        int size = Theme.S(32), x = Width - Theme.S(4) - (Chevron ? Theme.S(32) : 0);
        int y = (Height - size) / 2;
        for (int i = Buttons.Count - 1; i >= 0; i--) {
            x -= size;
            Buttons[i].Bounds = new Rectangle(x, y, size, size);
        }
    }

    int ButtonAt(Point p) {
        for (int i = 0; i < Buttons.Count; i++) if (Buttons[i].Bounds.Contains(p)) return i;
        return -1;
    }

    protected override void OnMouseMove(MouseEventArgs e) {
        int i = ButtonAt(e.Location);
        if (i != hotButton) {
            hotButton = i;
            tips.SetToolTip(this, i >= 0 ? Buttons[i].Tip : null);
            Invalidate();
        }
        base.OnMouseMove(e);
    }

    protected override void OnMouseLeave(EventArgs e) { hotButton = -1; base.OnMouseLeave(e); }

    protected override void OnClick(EventArgs e) {
        if (!Enabled) return;
        if (hotButton >= 0) {
            RowButton b = Buttons[hotButton];
            if (b.Enabled && ButtonClick != null) ButtonClick(this, new TagEventArgs(b.Tag));
            return;
        }
        base.OnClick(e);
    }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        LayoutButtons();
        int r4 = Theme.S(4);
        Rectangle bg = new Rectangle(Theme.S(4), Theme.S(1), Width - Theme.S(8), Height - Theme.S(2));
        if (Enabled && (hot || Expanded)) Theme.FillRound(g, down && hotButton < 0 ? Theme.Press : Theme.Hover, bg, r4);

        Color text = Enabled ? Theme.Text : Theme.Disabled;
        Color sub = Enabled ? Theme.SubText : Theme.Disabled;
        int box = Theme.S(32), left = Theme.S(12);
        Rectangle icon = new Rectangle(left, (Height - box) / 2, box, box);
        if (!string.IsNullOrEmpty(Avatar)) {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle a = Rectangle.Inflate(icon, -Theme.S(2), -Theme.S(2));
            using (SolidBrush b = new SolidBrush(Enabled ? AvatarColor : Theme.Disabled)) g.FillEllipse(b, a);
            Theme.Draw(g, Avatar, Theme.Avatar, Color.White, a, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
        } else if (!string.IsNullOrEmpty(Icon)) {
            Color c = !Enabled ? Theme.Disabled : IconColor != Color.Empty ? IconColor : Strong ? Theme.Accent : Theme.Text;
            Theme.Glyph(g, Icon, Theme.Icons, c, icon);
        }

        int x = icon.Right + Theme.S(12);
        int right = Width - Theme.S(12) - (Chevron ? Theme.S(28) : 0) - Buttons.Count * Theme.S(32);
        TextFormatFlags one = TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.VerticalCenter;
        Font title = Strong ? Theme.Strong : Theme.Body;
        if (string.IsNullOrEmpty(Detail)) {
            Theme.Draw(g, Title, title, text, new Rectangle(x, 0, right - x, Height), one);
        } else {
            int th = title.Height, dh = Theme.Small.Height, top = (Height - th - dh) / 2;
            Theme.Draw(g, Title, title, text, new Rectangle(x, top, right - x, th), one);
            Theme.Draw(g, Detail, Theme.Small, sub, new Rectangle(x, top + th, right - x, dh), one);
        }

        for (int i = 0; i < Buttons.Count; i++) {
            RowButton b = Buttons[i];
            bool on = Enabled && b.Enabled;
            if (on && i == hotButton) Theme.FillRound(g, down ? Theme.Press : Theme.Card, Rectangle.Inflate(b.Bounds, -Theme.S(2), -Theme.S(2)), r4);
            Theme.Glyph(g, b.Glyph, Theme.IconsSmall, on ? Theme.Text : Theme.Disabled, b.Bounds);
        }
        if (Chevron) {
            Rectangle c = new Rectangle(Width - Theme.S(36), 0, Theme.S(28), Height);
            Theme.Glyph(g, Theme.Glyph(Expanded ? "up" : "down"), Theme.IconsSmall, sub, c);
        }
    }
}

// A button with a label, an icon or both, for destructive actions inside an
// expanded row, such as Remove, and side by side in a Bar.
public class Chip : Widget {
    public string Icon, Label;
    // Checked shows a tick on the accent colour; Primary just the colour;
    // Danger is red, for one to think twice about.
    public bool Checked, Primary, Strong, Danger;
    public Color IconColor = Color.Empty;
    public string Tip;

    public Chip() { AutoSize = true; Margin = new Padding(0, 0, Theme.S(6), Theme.S(6)); }

    protected override void OnMouseEnter(EventArgs e) { tips.SetToolTip(this, Tip); base.OnMouseEnter(e); }

    public override Size GetPreferredSize(Size proposed) {
        if (string.IsNullOrEmpty(Label)) return new Size(Theme.S(36), Theme.S(32));
        int w = Theme.S(12) * 2 + Theme.Measure(Label, Strong ? Theme.Strong : Theme.Body);
        if (!string.IsNullOrEmpty(Icon)) w += Theme.S(16) + (string.IsNullOrEmpty(Label) ? 0 : Theme.S(8));
        if (Checked) w += Theme.S(16) + Theme.S(6);
        return new Size(w, Theme.S(32));
    }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        Rectangle r = new Rectangle(0, 0, Width - 1, Height - 1);
        int radius = Theme.S(4);
        Color fill, text;
        if (Checked || Primary) {
            fill = Enabled ? Theme.Accent : Theme.Disabled;
            text = Theme.OnAccent;
            if (hot && Enabled) fill = ControlPaint.Light(fill, 0.1f);
            Theme.FillRound(g, fill, r, radius);
        } else if (Danger && Enabled) {
            fill = Theme.Mix(Theme.DangerTint, Theme.Danger, down ? 0.2 : hot ? 0.1 : 0);
            text = Theme.Danger;
            Theme.FillRound(g, fill, r, radius);
        } else {
            fill = !Enabled ? Theme.ChipFill : down ? Theme.Press : hot ? Theme.ChipHover : Theme.ChipFill;
            text = Enabled ? Theme.Text : Theme.Disabled;
            Theme.FillRound(g, fill, r, radius);
            Theme.DrawRound(g, Strong && Enabled ? Theme.Accent : Theme.ChipBorder, r, radius);
        }
        int x = Theme.S(12);
        int w = GetPreferredSize(Size.Empty).Width;
        if (string.IsNullOrEmpty(Label)) x = (Width - Theme.S(16)) / 2;
        if (Width > w) x += (Width - w) / 2;
        if (Checked) {
            Theme.Glyph(g, Theme.Glyph("check"), Theme.IconsSmall, text, new Rectangle(x, 0, Theme.S(16), Height));
            x += Theme.S(16) + Theme.S(6);
        }
        if (!string.IsNullOrEmpty(Icon)) {
            Color ic = Checked || Primary || Danger || !Enabled ? text : IconColor != Color.Empty ? IconColor : Strong ? Theme.Accent : text;
            Theme.Glyph(g, Icon, Theme.IconsSmall, ic, new Rectangle(x, 0, Theme.S(16), Height));
            x += Theme.S(16) + Theme.S(8);
        }
        if (!string.IsNullOrEmpty(Label))
            Theme.Draw(g, Label, Strong ? Theme.Strong : Theme.Body, text, new Rectangle(x, 0, Width - x, Height),
                TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
    }
}

// A setting with a caption on the left and its value in a box on the right,
// which opens a list of the values to pick from.
public class Field : Widget {
    public string Caption, Value;

    public override Size GetPreferredSize(Size proposed) { return new Size(proposed.Width, Theme.S(32)); }

    Rectangle Box() {
        int w = Theme.Measure(Value, Theme.Body) + Theme.S(12 + 12 + 16 + 8);
        w = Math.Min(Width, Math.Max(w, Theme.S(120)));
        return new Rectangle(Width - w, 0, w - 1, Height - 1);
    }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        Rectangle box = Box();
        TextFormatFlags one = TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis;
        Theme.Draw(g, Caption, Theme.Body, Enabled ? Theme.Text : Theme.Disabled, new Rectangle(0, 0, box.Left - Theme.S(8), Height), one);
        Theme.FillRound(g, !Enabled ? Theme.ChipFill : down ? Theme.Press : hot ? Theme.ChipHover : Theme.ChipFill, box, Theme.S(4));
        Theme.DrawRound(g, Theme.ChipBorder, box, Theme.S(4));
        Color text = Enabled ? Theme.Text : Theme.Disabled;
        Theme.Draw(g, Value, Theme.Body, text, new Rectangle(box.Left + Theme.S(12), 0, box.Width - Theme.S(44), Height), one);
        Theme.Glyph(g, Theme.Glyph("down"), Theme.IconsSmall, Enabled ? Theme.SubText : Theme.Disabled,
            new Rectangle(box.Right - Theme.S(32), 0, Theme.S(24), Height));
    }
}

// Chips that wrap onto as many lines as they need.
public class Flow : FlowLayoutPanel {
    public Flow() {
        WrapContents = true;
        AutoSize = false;
        Margin = Padding.Empty;
        Padding = Padding.Empty;
        DoubleBuffered = true;
        BackColor = Theme.Card;
    }

    public override Size GetPreferredSize(Size proposed) {
        // As FlowLayoutPanel's, without the bottom margin of the last line.
        Size s = base.GetPreferredSize(new Size(proposed.Width, 0));
        return new Size(proposed.Width, Math.Max(0, s.Height - Theme.S(6)));
    }
}

// A small link to an action, inside an expanded row: its icon, and its label
// in the accent colour, underlined under the mouse.
public class Link : Widget {
    public string Icon, Label;

    public Link() { Cursor = Cursors.Hand; }

    int TextLeft { get { return string.IsNullOrEmpty(Icon) ? 0 : Theme.S(16 + 8); } }

    // The label as a tooltip, if it doesn't fit.
    protected override void OnMouseEnter(EventArgs e) {
        tips.SetToolTip(this, Theme.Measure(Label, Theme.Body) > Width - TextLeft ? Label : null);
        base.OnMouseEnter(e);
    }

    public override Size GetPreferredSize(Size proposed) { return new Size(proposed.Width, Theme.S(28)); }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        if (!string.IsNullOrEmpty(Icon))
            Theme.Glyph(g, Icon, Theme.IconsSmall, Enabled ? Theme.SubText : Theme.Disabled, new Rectangle(0, 0, Theme.S(16), Height));
        Theme.Draw(g, Label, hot && Enabled ? Theme.Underlined : Theme.Body, Enabled ? Theme.Accent : Theme.Disabled,
            new Rectangle(TextLeft, 0, Width - TextLeft, Height),
            TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
    }
}

// Links two to a line, each group of them starting a new line.
public class Grid : Panel {
    public readonly HashSet<Control> GroupStarts = new HashSet<Control>();

    public Grid() {
        DoubleBuffered = true;
        Margin = Padding.Empty;
        BackColor = Theme.Card;
    }

    protected override void OnControlRemoved(ControlEventArgs e) { GroupStarts.Remove(e.Control); base.OnControlRemoved(e); }

    // Place the links for WIDTH, or only measure them, and return the height.
    int Place(int width, bool apply) {
        int h = Theme.S(28), gap = Theme.S(8), column = (width - gap) / 2, col = 0, y = 0;
        bool first = true;
        foreach (Control c in Controls) {
            if (!first && GroupStarts.Contains(c)) {
                if (col != 0) y += h;
                col = 0;
            }
            if (apply) c.SetBounds(col * (column + gap), y, column, h);
            first = false;
            if (++col == 2) { col = 0; y += h; }
        }
        return col == 0 ? y : y + h;
    }

    public override Size GetPreferredSize(Size proposed) { return new Size(proposed.Width, Place(proposed.Width, false)); }

    protected override void OnLayout(LayoutEventArgs e) { Place(ClientSize.Width, true); }
}

// Controls side by side, sharing the width: Start, Stop and so on.
public class Bar : Panel {
    public Bar() { DoubleBuffered = true; BackColor = Theme.Back; Margin = new Padding(Theme.S(12), Theme.S(4), Theme.S(12), Theme.S(4)); }

    public override Size GetPreferredSize(Size proposed) { return new Size(proposed.Width, Theme.S(36)); }

    protected override void OnLayout(LayoutEventArgs e) {
        int n = Controls.Count, gap = Theme.S(8);
        if (n == 0) return;
        int w = (ClientSize.Width - gap * (n - 1)) / n;
        for (int i = 0; i < n; i++)
            Controls[i].SetBounds(i * (w + gap), 0, i == n - 1 ? ClientSize.Width - i * (w + gap) : w, ClientSize.Height);
    }
}

// Controls one above the other, each as wide as the stack and as tall as it
// wants to be. It scrolls when AutoScroll is set and it's too short for them.
public class Stack : Panel {
    // Whether to draw a rounded card behind the controls.
    public bool Card;
    // Controls left out, tracked here as Visible is false for every control
    // while the window is hidden.
    readonly HashSet<Control> collapsed = new HashSet<Control>();

    public void Collapse(Control c, bool collapse) {
        if (collapse) collapsed.Add(c); else collapsed.Remove(c);
        c.Visible = !collapse;
        PerformLayout();
    }

    protected override void OnControlRemoved(ControlEventArgs e) { collapsed.Remove(e.Control); base.OnControlRemoved(e); }

    public Stack() {
        DoubleBuffered = true;
        SetStyle(ControlStyles.ResizeRedraw, true);
        Margin = Padding.Empty;
    }

    static int Want(Control c, int width) { return c.GetPreferredSize(new Size(width, 0)).Height; }

    public int Measure(int width) {
        int y = Padding.Top;
        foreach (Control c in Controls) {
            if (collapsed.Contains(c)) continue;
            y += c.Margin.Vertical + Want(c, width - Padding.Horizontal - c.Margin.Horizontal);
        }
        return y + Padding.Bottom;
    }

    public override Size GetPreferredSize(Size proposed) { return new Size(proposed.Width, Measure(proposed.Width)); }

    protected override void OnLayout(LayoutEventArgs e) {
        int width = ClientSize.Width, y = Padding.Top + AutoScrollPosition.Y;
        foreach (Control c in Controls) {
            if (collapsed.Contains(c)) continue;
            int w = width - Padding.Horizontal - c.Margin.Horizontal;
            int h = Want(c, w);
            c.SetBounds(Padding.Left + c.Margin.Left, y + c.Margin.Top, w, h);
            y += c.Margin.Vertical + h;
        }
        if (AutoScroll) {
            Size min = new Size(0, y - AutoScrollPosition.Y + Padding.Bottom);
            if (AutoScrollMinSize != min) AutoScrollMinSize = min;
        }
        // Which updates the scroll bar. It leaves the controls where they are,
        // as they're anchored to the top left.
        base.OnLayout(e);
    }

    // The wheel scrolls it from anywhere over it, not only over the scroll
    // bar: the controls in it pass the wheel on to it.
    public void Wheel(int delta) {
        if (!AutoScroll) return;
        int y = -AutoScrollPosition.Y - (int) (delta / 120.0 * Theme.S(40) * SystemInformation.MouseWheelScrollLines / 3);
        AutoScrollPosition = new Point(0, Math.Max(0, y));
    }

    protected override void OnPaintBackground(PaintEventArgs e) {
        if (!Card) { base.OnPaintBackground(e); return; }
        e.Graphics.Clear(Parent != null ? Parent.BackColor : Theme.Back);
        Theme.FillRound(e.Graphics, BackColor, new Rectangle(0, 0, Width - 1, Height - 1), Theme.S(6));
    }
}

// A section's heading.
public class Heading : Widget {
    public string Label;
    public override Size GetPreferredSize(Size proposed) { return new Size(proposed.Width, Theme.S(30)); }
    protected override void OnPaint(PaintEventArgs e) {
        Theme.Draw(e.Graphics, Label, Theme.SmallStrong, Theme.SubText,
            new Rectangle(Theme.S(14), Theme.S(8), Width - Theme.S(28), Height - Theme.S(10)),
            TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
    }
}

public class Divider : Widget {
    public override Size GetPreferredSize(Size proposed) { return new Size(proposed.Width, Theme.S(13)); }
    protected override void OnPaint(PaintEventArgs e) {
        using (Pen p = new Pen(Theme.Divider)) e.Graphics.DrawLine(p, Theme.S(12), Height / 2, Width - Theme.S(12), Height / 2);
    }
}

// The panel's heading: the app's icon, its name and its status.
// With Tip set, it's also a button, e.g. to open the dashboard.
public class Header : Widget {
    public Image Image;
    public string Title, Status, State, Tip;

    bool Clickable { get { return Enabled && !string.IsNullOrEmpty(Tip); } }

    public override Size GetPreferredSize(Size proposed) { return new Size(proposed.Width, Theme.S(68)); }

    protected override void OnMouseEnter(EventArgs e) { tips.SetToolTip(this, Clickable ? Tip : null); base.OnMouseEnter(e); }

    protected override void OnClick(EventArgs e) { if (Clickable) base.OnClick(e); }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        int size = Theme.S(36), x = Theme.S(16);
        if (Clickable && hot) {
            Rectangle r = new Rectangle(Theme.S(6), Theme.S(4), Width - Theme.S(12), Height - Theme.S(8));
            Theme.FillRound(g, down ? Theme.Press : Theme.Hover, r, Theme.S(6));
            Theme.Glyph(g, Theme.Glyph("open"), Theme.IconsSmall, Theme.SubText,
                new Rectangle(Width - Theme.S(44), 0, Theme.S(32), Height));
        }
        if (Image != null) {
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.DrawImage(Image, new Rectangle(x, (Height - size) / 2, size, size));
            x += size + Theme.S(12);
        }
        int th = Theme.Title.Height, sh = Theme.Small.Height, top = (Height - th - sh) / 2;
        TextFormatFlags one = TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.VerticalCenter;
        Theme.Draw(g, Title, Theme.Title, Theme.Text, new Rectangle(x, top - Theme.S(1), Width - x - Theme.S(16), th), one);
        int dot = Theme.S(8);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (SolidBrush b = new SolidBrush(Theme.StatusColor(State)))
            g.FillEllipse(b, x, top + th + (sh - dot) / 2 + Theme.S(1), dot, dot);
        Theme.Draw(g, Status, Theme.Small, Theme.SubText, new Rectangle(x + dot + Theme.S(6), top + th, Width - x - dot - Theme.S(22), sh), one);
    }
}

// A message about something that's wrong, in a tinted box.
public class Banner : Widget {
    public string Message;

    public Banner() { Margin = new Padding(Theme.S(12), 0, Theme.S(12), Theme.S(8)); }

    const TextFormatFlags Wrap = TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding;

    int TextWidth(int width) { return width - Theme.S(48); }

    public override Size GetPreferredSize(Size proposed) {
        Size s = TextRenderer.MeasureText(Message ?? "", Theme.Small, new Size(TextWidth(proposed.Width), 0), Wrap);
        return new Size(proposed.Width, Math.Max(Theme.S(36), s.Height + Theme.S(20)));
    }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        Theme.FillRound(g, Theme.DangerTint, new Rectangle(0, 0, Width - 1, Height - 1), Theme.S(6));
        Theme.Glyph(g, Theme.Glyph("error"), Theme.IconsSmall, Theme.Danger, new Rectangle(Theme.S(10), Theme.S(10), Theme.S(18), Theme.Small.Height));
        Theme.Draw(g, Message, Theme.Small, Theme.Text, new Rectangle(Theme.S(36), Theme.S(10), TextWidth(Width), Height - Theme.S(20)), Wrap);
    }
}

// A thin bar that shows something is happening.
public class Progress : Widget {
    readonly Timer timer = new Timer();
    int phase;

    public Progress() {
        Margin = new Padding(Theme.S(16), 0, Theme.S(16), Theme.S(6));
        timer.Interval = 16;
        timer.Tick += delegate { phase = (phase + 1) % 120; Invalidate(); };
    }

    public override Size GetPreferredSize(Size proposed) { return new Size(proposed.Width, Theme.S(3)); }

    protected override void OnVisibleChanged(EventArgs e) { timer.Enabled = Visible; base.OnVisibleChanged(e); }
    protected override void OnHandleCreated(EventArgs e) { timer.Enabled = Visible; base.OnHandleCreated(e); }
    protected override void Dispose(bool disposing) { if (disposing) timer.Dispose(); base.Dispose(disposing); }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        int h = Height;
        Theme.FillRound(g, Theme.Divider, new Rectangle(0, 0, Width - 1, h - 1), h / 2);
        // A segment that eases across and wraps round.
        double t = phase / 120.0;
        double eased = t < 0.5 ? 2 * t * t : 1 - Math.Pow(-2 * t + 2, 2) / 2;
        int seg = Width / 3;
        int x = (int) (eased * (Width + seg)) - seg;
        Rectangle r = Rectangle.Intersect(new Rectangle(x, 0, seg, h - 1), new Rectangle(0, 0, Width - 1, h - 1));
        if (r.Width > 0) Theme.FillRound(g, Theme.Accent, r, h / 2);
    }
}

// A button that's only an icon, with a tooltip.
public class IconButton : Widget {
    public string Icon, Tip;
    // A dot in the corner in this colour, e.g. for news; none if Empty.
    public Color Badge = Color.Empty;

    public IconButton() { Size = new Size(Theme.S(36), Theme.S(36)); }

    protected override void OnMouseEnter(EventArgs e) { tips.SetToolTip(this, Tip); base.OnMouseEnter(e); }

    protected override void OnPaint(PaintEventArgs e) {
        Rectangle r = new Rectangle(0, 0, Width - 1, Height - 1);
        if (Enabled && hot) Theme.FillRound(e.Graphics, down ? Theme.Press : Theme.Hover, r, Theme.S(4));
        Theme.Glyph(e.Graphics, Icon, Theme.Icons, Enabled ? Theme.Text : Theme.Disabled, r);
        if (Badge != Color.Empty && Enabled) {
            // A ring in the background colour sets it apart from the icon.
            int d = Theme.S(8), ring = Theme.S(2);
            Rectangle dot = new Rectangle(Width - d - Theme.S(7), Theme.S(7), d, d);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (SolidBrush b = new SolidBrush(Parent != null ? Parent.BackColor : Theme.Footer))
                e.Graphics.FillEllipse(b, Rectangle.Inflate(dot, ring, ring));
            using (SolidBrush b = new SolidBrush(Badge)) e.Graphics.FillEllipse(b, dot);
        }
    }
}

// The bottom of the panel: a note on the left and icon buttons on the right.
public class Footer : Panel {
    public string Note;

    public Footer() {
        DoubleBuffered = true;
        SetStyle(ControlStyles.ResizeRedraw, true);
        Height = Theme.S(52);
    }

    protected override void OnLayout(LayoutEventArgs e) {
        int x = ClientSize.Width - Theme.S(8);
        for (int i = Controls.Count - 1; i >= 0; i--) {
            Control c = Controls[i];
            x -= c.Width;
            c.Location = new Point(x, (ClientSize.Height - c.Height) / 2 + Theme.S(1));
            x -= Theme.S(2);
        }
    }

    protected override void OnPaint(PaintEventArgs e) {
        e.Graphics.Clear(Theme.Footer);
        using (Pen p = new Pen(Theme.Divider)) e.Graphics.DrawLine(p, 0, 0, Width, 0);
        int right = Width - Theme.S(16);
        foreach (Control c in Controls) right = Math.Min(right, c.Left - Theme.S(8));
        Theme.Draw(e.Graphics, Note, Theme.Small, Theme.SubText, new Rectangle(Theme.S(16), 0, right - Theme.S(16), Height),
            TextFormatFlags.SingleLine | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
    }
}

// The panel that opens from the notification area: borderless, with rounded
// corners and a shadow, and gone again when you click elsewhere.
public class Flyout : Form {
    public readonly Stack Head = new Stack();
    public readonly Stack Body = new Stack();
    public readonly Footer Foot = new Footer();
    // When it last hid, so a click on the tray icon that hid it doesn't
    // straight away show it again.
    public DateTime HiddenAt = DateTime.MinValue;
    // While set, it stays open when something else is activated, e.g. a
    // submenu.
    public bool Hold;
    Point anchor;

    // Its width without a scroll bar, which it widens by when it scrolls,
    // so its contents don't have to squeeze up.
    public static int BaseWidth { get { return Theme.S(360); } }

    public Flyout() {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        KeyPreview = true;
        DoubleBuffered = true;
        Text = "Novacore";
        Width = BaseWidth;
        Head.Padding = new Padding(0, Theme.S(4), 0, 0);
        Body.Padding = new Padding(0, 0, 0, Theme.S(8));
        Controls.Add(Head);
        Controls.Add(Body);
        Controls.Add(Foot);
        ApplyTheme();
    }

    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.ClassStyle |= 0x20000;  // CS_DROPSHADOW
            cp.ExStyle |= 0x80;        // WS_EX_TOOLWINDOW: not in Alt+Tab
            return cp;
        }
    }

    public void ApplyTheme() {
        BackColor = Head.BackColor = Body.BackColor = Theme.Back;
        Foot.BackColor = Theme.Footer;
        if (IsHandleCreated) {
            Theme.BorderColor(Handle, Theme.Border);
            Theme.ThemeScrollBars(Body);
        }
        Invalidate(true);
    }

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        Theme.RoundCorners(Handle, false);
        Theme.BorderColor(Handle, Theme.Border);
        Theme.ThemeScrollBars(Body);
    }

    // Remove everything but the footer's note.
    public void Clear() {
        foreach (Control parent in new Control[] { Head, Body, Foot }) {
            List<Control> old = new List<Control>();
            foreach (Control c in parent.Controls) old.Add(c);
            parent.Controls.Clear();
            foreach (Control c in old) c.Dispose();
        }
        Body.AutoScrollPosition = Point.Empty;
    }

    // Size it to fit its contents, as far as the screen allows, and put it
    // back by the notification area.
    public void Reflow() {
        Rectangle wa = Screen.FromPoint(anchor).WorkingArea;
        int w = BaseWidth;
        int th = Head.Measure(w), bh = Body.Measure(w), fh = Foot.Height;
        // No taller than Windows' own flyouts: three quarters of the screen.
        int room = Math.Max(Theme.S(120), wa.Height * 3 / 4 - th - fh);
        int visible = Math.Min(bh, room);
        bool scroll = bh > visible;
        if (Body.AutoScroll != scroll) {
            Body.AutoScroll = scroll;
            if (!scroll) Body.AutoScrollMinSize = Size.Empty;
        }
        if (scroll) w += SystemInformation.VerticalScrollBarWidth;
        SuspendLayout();
        Head.SetBounds(0, 0, w, th);
        Body.SetBounds(0, th, w, visible);
        Foot.SetBounds(0, th + visible, w, fh);
        ClientSize = new Size(w, th + visible + fh);
        ResumeLayout(true);
        Body.PerformLayout();
        Place();
    }

    void Place() {
        Screen screen = Screen.FromPoint(anchor);
        Rectangle wa = screen.WorkingArea, b = screen.Bounds;
        int m = Theme.S(12), x, y;
        if (wa.Bottom < b.Bottom) { x = anchor.X - Width / 2; y = wa.Bottom - Height - m; }
        else if (wa.Top > b.Top) { x = anchor.X - Width / 2; y = wa.Top + m; }
        else if (wa.Left > b.Left) { x = wa.Left + m; y = anchor.Y - Height / 2; }
        else if (wa.Right < b.Right) { x = wa.Right - Width - m; y = anchor.Y - Height / 2; }
        else { x = wa.Right - Width - m; y = wa.Bottom - Height - m; }
        x = Math.Max(wa.Left + m, Math.Min(x, wa.Right - Width - m));
        y = Math.Max(wa.Top + m, Math.Min(y, wa.Bottom - Height - m));
        Location = new Point(x, y);
    }

    // Show it by POINT, the notification area icon that was clicked.
    public void ShowAt(Point point) {
        anchor = point;
        Reflow();
        Show();
        Activate();
        Theme.SetForegroundWindow(Handle);
    }

    protected override void OnDeactivate(EventArgs e) {
        base.OnDeactivate(e);
        if (Hold) return;
        Hide();
    }

    protected override void OnVisibleChanged(EventArgs e) {
        base.OnVisibleChanged(e);
        if (!Visible) HiddenAt = DateTime.Now;
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keys) {
        if (keys == Keys.Escape) { Hide(); return true; }
        return base.ProcessCmdKey(ref msg, keys);
    }
}

}
