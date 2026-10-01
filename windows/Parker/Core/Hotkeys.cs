using System;
using System.Collections.Generic;
using System.Windows.Forms;

namespace Parker
{
    /// <summary>Global hotkeys through RegisterHotKey on a hidden message window.</summary>
    internal sealed class Hotkeys : NativeWindow, IDisposable
    {
        public sealed class Binding
        {
            public string Name;
            public uint Modifiers;
            public Keys Key;
            public Action Action;
            public string Display
            {
                get
                {
                    var parts = new List<string>();
                    if ((Modifiers & Native.MOD_CONTROL) != 0) parts.Add("Ctrl");
                    if ((Modifiers & Native.MOD_ALT) != 0) parts.Add("Alt");
                    if ((Modifiers & Native.MOD_SHIFT) != 0) parts.Add("Maj");
                    if ((Modifiers & Native.MOD_WIN) != 0) parts.Add("Win");
                    var k = Key.ToString();
                    if (k.StartsWith("D") && k.Length == 2) k = k.Substring(1);
                    parts.Add(k);
                    return string.Join("+", parts);
                }
            }
        }

        readonly Dictionary<int, Binding> registered = new Dictionary<int, Binding>();
        public readonly List<Binding> Failed = new List<Binding>();
        int nextId = 1;

        public Hotkeys()
        {
            CreateHandle(new CreateParams());
        }

        public void Register(Binding b)
        {
            var id = nextId++;
            if (Native.RegisterHotKey(Handle, id, b.Modifiers | Native.MOD_NOREPEAT, (uint)b.Key)) registered[id] = b;
            else Failed.Add(b);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == Native.WM_HOTKEY)
            {
                Binding b;
                if (registered.TryGetValue(m.WParam.ToInt32(), out b) && b.Action != null) b.Action();
                return;
            }
            base.WndProc(ref m);
        }

        public void Dispose()
        {
            foreach (var id in registered.Keys) Native.UnregisterHotKey(Handle, id);
            registered.Clear();
            DestroyHandle();
        }
    }
}
