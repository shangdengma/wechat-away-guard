using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Windows.Foundation;
using Windows.Devices.Bluetooth;
using Windows.Devices.Enumeration;
using Windows.Media.Ocr;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;
using Windows.Networking.Sockets;
using Point = System.Drawing.Point;
using Size = System.Drawing.Size;

namespace WeChatGuard {
enum Signal { Present, Missing, Unknown }
sealed class Presence {
    public bool Armed, Latched;
    public int Good;
    public double? Lost;
    public bool Step(Signal signal, double now, int delay) {
        if (signal == Signal.Present) {
            Lost = null;
            if (++Good >= 2) { Armed = true; Latched = false; }
            return false;
        }
        Good = 0;
        if (!Armed || Latched) return false;
        if (!Lost.HasValue) Lost = now;
        if (now - Lost.Value < delay) return false;
        Latched = true;
        return true;
    }
}
static class WinAsync {
    public static async Task WaitAction(IAsyncAction op,int ms) {
        var watch=Stopwatch.StartNew();
        try {
            while(op.Status==AsyncStatus.Started) {
                if(watch.ElapsedMilliseconds>ms){op.Cancel();throw new TimeoutException();}
                await Task.Delay(100);
            }
            if(op.Status==AsyncStatus.Error)throw op.ErrorCode;
            if(op.Status==AsyncStatus.Canceled)throw new OperationCanceledException();
            op.GetResults();
        } finally { try{op.Close();}catch{} }
    }
    public static async Task<T> Wait<T>(IAsyncOperation<T> op, int ms) {
        var sw = Stopwatch.StartNew();
        try {
            while(op.Status == AsyncStatus.Started) {
                if (sw.ElapsedMilliseconds > ms) { op.Cancel(); throw new TimeoutException(); }
                await Task.Delay(100);
            }
            if(op.Status == AsyncStatus.Error) throw op.ErrorCode;
            if(op.Status == AsyncStatus.Canceled) throw new OperationCanceledException();
            return op.GetResults();
        } finally { try { op.Close(); } catch {} }
    }
}
sealed class DeviceChoice {
    public string Id, Name;
    public override string ToString() { return Name; }
}
sealed class ProbeResult {
    public Signal Signal;
    public string Note;
    public ProbeResult(Signal s,string n) { Signal=s; Note=n; }
}
static class Phone {
    public static Signal Classify(bool socketConnected, int serviceCount) {
        // SDP Success and even a nonempty service list are NOT live-presence evidence.
        if(socketConnected)return Signal.Present;
        return serviceCount==0?Signal.Unknown:Signal.Missing;
    }
    public static async Task<bool> RadioReady() {
        try {var adapter=await WinAsync.Wait(BluetoothAdapter.GetDefaultAsync(),5000);
            if(adapter==null)return false;
            var radio=await WinAsync.Wait(adapter.GetRadioAsync(),5000);
            return radio!=null && radio.State==Windows.Devices.Radios.RadioState.On;
        }catch{return false;}
    }
    public static async Task<List<DeviceChoice>> List() {
        var adapter = await WinAsync.Wait(BluetoothAdapter.GetDefaultAsync(), 5000);
        if(adapter == null) throw new InvalidOperationException("没有可用的蓝牙适配器。");
        var devices = await WinAsync.Wait(DeviceInformation.FindAllAsync(BluetoothDevice.GetDeviceSelectorFromPairingState(true)), 8000);
        var result = new List<DeviceChoice>();
        foreach(var d in devices) result.Add(new DeviceChoice { Id=d.Id, Name=d.Name });
        return result.OrderBy(d=>d.Name).ToList();
    }
    public static async Task<ProbeResult> Check(string id) {
        BluetoothDevice device=null;
        try {
            device=await WinAsync.Wait(BluetoothDevice.FromIdAsync(id),5000);
            if(device==null) return new ProbeResult(Signal.Unknown,"无法访问手机，请检查配对和蓝牙权限");
            // This query only discovers candidate endpoints. Its result may be stale.
            var r=await WinAsync.Wait(device.GetRfcommServicesAsync(BluetoothCacheMode.Uncached),8000);
            int count=r.Services.Count, attempts=0;string last="无可用服务";
            try {
                if(r.Error!=BluetoothError.Success)return new ProbeResult(Signal.Unknown,"服务查询异常："+r.Error);
                foreach(var service in r.Services) {
                    if(++attempts>3)break;
                    using(var socket=new StreamSocket()) {
                        try {
                            await WinAsync.WaitAction(socket.ConnectAsync(service.ConnectionHostName,service.ConnectionServiceName,SocketProtectionLevel.BluetoothEncryptionAllowNullAuthentication),3500);
                            // Establish and immediately dispose the transport. No read/write of user data.
                            return new ProbeResult(Classify(true,count),"本次蓝牙连接已建立（服务数 "+count+"）；连接已关闭");
                        } catch(TimeoutException) { last="连接超时"; }
                        catch(Exception ex) { last="连接失败 0x"+ex.HResult.ToString("X8"); }
                    }
                }
                return new ProbeResult(Classify(false,count),"没有建立本次蓝牙连接（服务数 "+count+"；"+last+"）");
            } finally {foreach(var service in r.Services)service.Dispose();}
        } catch(TimeoutException) { return new ProbeResult(Signal.Missing,"手机探测超时"); }
        catch(Exception ex) { return new ProbeResult(Signal.Unknown,"探测异常："+ex.GetType().Name); }
        finally { if(device!=null)device.Dispose(); }
    }
}
sealed class WxTarget {
    public IntPtr Handle;
    public uint Pid;
    public string Path, Version;
    public string Fingerprint { get { return Path+"|"+Version; } }
}
static class Native {
    public delegate bool EnumProc(IntPtr h,IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f,IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h,StringBuilder b,int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int c);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int k);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out Rect r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h,IntPtr dc,uint f);
    [DllImport("user32.dll",SetLastError=true)] public static extern uint SendInput(uint n,Input[] input,int size);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct Input { public uint type; public InputUnion data; }
    [StructLayout(LayoutKind.Explicit)] public struct InputUnion {
        [FieldOffset(0)] public Keyboard keyboard;
        [FieldOffset(0)] public Mouse mouse;
    }
    [StructLayout(LayoutKind.Sequential)] public struct Keyboard { public ushort vk,scan; public uint flags,time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] public struct Mouse { public int dx,dy; public uint data,flags,time; public UIntPtr extra; }
    public static Input Key(ushort key,bool up) { return new Input{type=1,data=new InputUnion{keyboard=new Keyboard{vk=key,flags=up?2u:0u}}}; }
    public static WxTarget Find() {
        var candidates=new List<WxTarget>();
        EnumWindows(delegate(IntPtr h,IntPtr l) {
            var name=new StringBuilder(256); GetWindowText(h,name,name.Capacity);
            if(name.ToString()!="微信" && name.ToString()!="WeChat" && name.ToString()!="Weixin") return true;
            uint pid; GetWindowThreadProcessId(h,out pid);
            try { using(var p=Process.GetProcessById((int)pid)) {
                if(!p.ProcessName.Equals("Weixin",StringComparison.OrdinalIgnoreCase) && !p.ProcessName.Equals("WeChat",StringComparison.OrdinalIgnoreCase))return true;
                var path=p.MainModule.FileName;
                candidates.Add(new WxTarget{Handle=h,Pid=pid,Path=path,Version=FileVersionInfo.GetVersionInfo(path).FileVersion});
            }} catch {}
            return true;
        },IntPtr.Zero);
        // Weixin 4.x also creates hidden helper windows titled 微信.
        // Bind only a visible main window during setup; later reuse that validated HWND.
        candidates=candidates.Where(t=>IsWindowVisible(t.Handle)).ToList();
        if(candidates.Count==0) throw new InvalidOperationException("未找到可见微信主窗口。请从托盘打开微信主界面后重试。");
        if(candidates.Count!=1) throw new InvalidOperationException("发现多个微信主窗口，原型暂不支持多开，请仅保留一个账号窗口。");
        return candidates[0];
    }
    public static bool Same(WxTarget t) {
        uint p; GetWindowThreadProcessId(t.Handle,out p); return p==t.Pid;
    }
}
sealed class LockResult { public bool Sent, Verified; public string Note,Fingerprint; }
static class WeChat {
    static WxTarget bound;
    public static bool LockText(string text) {
        string s=new string(text.Where(c=>!char.IsWhiteSpace(c)).ToArray()).ToLowerInvariant();
        return s.Contains("windows微信已被锁定") || s.Contains("windows微信已锁定") || s.Contains("wechatforwindowsislocked") || s.Contains("windowswechatislocked");
    }
    static async Task<bool> Verify(WxTarget target) {
        var engine=OcrEngine.TryCreateFromUserProfileLanguages();
        if(engine==null || !Native.Same(target)) return false;
        Native.Rect rect; if(!Native.GetWindowRect(target.Handle,out rect))return false;
        int w=rect.Right-rect.Left,h=rect.Bottom-rect.Top;
        if(w<200||h<150||w>5000||h>4000)return false;
        using(var bitmap=new Bitmap(w,h,PixelFormat.Format32bppArgb)) {
            using(var g=Graphics.FromImage(bitmap)) {
                IntPtr dc=g.GetHdc(); bool ok;
                try { ok=Native.PrintWindow(target.Handle,dc,2); } finally { g.ReleaseHdc(dc); }
                if(!ok)return false;
            }
            using(var bytes=new MemoryStream()) {
                bitmap.Save(bytes,ImageFormat.Png);
                using(var stream=new InMemoryRandomAccessStream()) {
                    using(var writer=new DataWriter(stream.GetOutputStreamAt(0))) {
                        writer.WriteBytes(bytes.ToArray());
                        await WinAsync.Wait(writer.StoreAsync(),3000);
                        writer.DetachStream();
                    }
                    stream.Seek(0);
                    var decoder=await WinAsync.Wait(BitmapDecoder.CreateAsync(stream),3000);
                    using(var software=await WinAsync.Wait(decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8,BitmapAlphaMode.Premultiplied),3000)) {
                        var result=await WinAsync.Wait(engine.RecognizeAsync(software),4000);
                        // OCR only runs after a lock command; never store/log its text or image.
                        return LockText(result.Text);
                    }
                }
            }
        }
    }
    public static async Task<LockResult> Lock(string requiredFingerprint) {
        var r=new LockResult();
        try {
            WxTarget t;
            if(requiredFingerprint!=null && bound!=null && Native.Same(bound)) {
                t=bound;
                using(var process=Process.GetProcessById((int)t.Pid)) {
                    t.Path=process.MainModule.FileName;
                    t.Version=FileVersionInfo.GetVersionInfo(t.Path).FileVersion;
                }
            } else t=Native.Find();
            r.Fingerprint=t.Fingerprint;
            if(requiredFingerprint!=null && t.Fingerprint!=requiredFingerprint)
                throw new InvalidOperationException("微信版本或路径已变化，请重新测试锁定。");
            if(Native.IsIconic(t.Handle))Native.ShowWindow(t.Handle,9);
            else Native.ShowWindow(t.Handle,5);
            Native.SetForegroundWindow(t.Handle);
            await Task.Delay(400);
            if(Native.GetForegroundWindow()!=t.Handle || !Native.Same(t))
                throw new InvalidOperationException("无法激活微信，已取消按键，避免发给其他软件。");
            foreach(int key in new int[]{0x10,0x11,0x12,0x5B,0x5C})
                if((Native.GetAsyncKeyState(key)&0x8000)!=0)throw new InvalidOperationException("有修饰键按住，请松开后重试。");
            // Single SendInput batch; no text, Enter, password or system-lock shortcut.
            var keys=new Native.Input[]{Native.Key(0x11,false),Native.Key(0x4C,false),Native.Key(0x4C,true),Native.Key(0x11,true)};
            if(Native.SendInput(4,keys,Marshal.SizeOf(typeof(Native.Input)))!=4)
                throw new InvalidOperationException("Windows 未接受完整快捷键，可能存在权限差异。");
            r.Sent=true;
            bound=t;
            await Task.Delay(1600);
            try { r.Verified=await Verify(t); } catch { r.Verified=false; }
            r.Note=r.Verified?"已识别微信原生锁定页面":"已发送 Ctrl+L，但未能自动确认锁定；请查看微信";
        } catch(Exception ex) { r.Note=ex.Message; }
        return r;
    }
}
static class Program {
    static void Assert(bool condition,string name){if(!condition)throw new Exception(name);}
    static string Tests(){int count=0;Action<bool,string> a=(v,n)=>{Assert(v,n);count++;};
        var p=new Presence();a(!p.Step(Signal.Missing,0,20),"no lock before presence");a(!p.Step(Signal.Present,1,20)&&!p.Armed,"first positive");p.Step(Signal.Present,6,20);a(p.Armed,"armed after two positives");a(!p.Step(Signal.Missing,10,20),"start loss");a(!p.Step(Signal.Missing,29,20),"debounce");a(p.Step(Signal.Missing,30,20),"trigger at deadline");a(!p.Step(Signal.Missing,50,20),"latch prevents repeated actions");p.Step(Signal.Present,55,20);a(p.Latched,"one positive does not rearm");p.Step(Signal.Present,60,20);a(!p.Latched,"two positives rearm");p.Step(Signal.Unknown,65,20);a(p.Step(Signal.Unknown,85,20),"sensor failure also triggers protection");
        var q=new Presence();q.Step(Signal.Present,0,10);q.Step(Signal.Present,5,10);q.Step(Signal.Missing,10,10);q.Step(Signal.Present,14,10);a(!q.Step(Signal.Missing,22,10),"brief disconnect cleared");a(!q.Step(Signal.Missing,31,10),"new deadline");a(q.Step(Signal.Missing,32,10),"new deadline triggers");
        a(WeChat.LockText("Windows 微信已被锁定"),"lock text");a(!WeChat.LockText("微信，锁定，聊天"),"generic text rejected");a(Marshal.SizeOf(typeof(Native.Input))==40,"x64 SendInput ABI");
        a(Phone.Classify(false,5)==Signal.Missing,"SDP Success with 5 stale services is not presence");
        a(Phone.Classify(false,0)==Signal.Unknown,"empty Success is not presence");
        a(Phone.Classify(true,5)==Signal.Present,"fresh socket required for presence");
        var gate=new SetupGate(0);
        a(gate.Step(Signal.Present,1,20,true)==0,"setup needs two live connections");
        a(gate.Step(Signal.Present,6,20,true)==1,"setup requests phone off");
        a(gate.Step(Signal.Missing,10,20,true)==1,"setup waits off delay");
        a(gate.Step(Signal.Missing,30,20,true)==2,"setup waits same phone return");
        a(gate.Step(Signal.Present,35,20,true)==2,"setup needs two return connections");
        a(gate.Step(Signal.Present,40,20,true)==3,"setup complete");
        var off=new SetupGate(0);off.Step(Signal.Present,1,20,true);off.Step(Signal.Present,6,20,true);
        a(off.Step(Signal.Missing,10,20,false)==-1,"computer radio off never validates phone");
        a(new SetupGate(0).Step(Signal.Present,181,20,true)==-1,"setup timeout");
        var stale=new Profile{DeviceId="test",VerifiedUtc=new DateTime(2026,1,1,0,0,0,DateTimeKind.Utc)};
        a(stale.Valid(stale.VerifiedUtc.AddDays(6)),"recent calibration remembered");
        a(!stale.Valid(stale.VerifiedUtc.AddDays(7)),"calibration expires");
        a(!stale.Valid(stale.VerifiedUtc.AddDays(-1)),"future calibration rejected");
        a(!new Profile().Valid(DateTime.UtcNow),"empty settings never bypass setup");
        return "PASS "+count+" tests. No Bluetooth, key injection or WeChat operation performed.";
    }
    [STAThread] static void Main(string[] args){
        if(args.Length>0&&args[0]=="--self-test"){try{File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"self-test.txt"),Tests(),Encoding.UTF8);Environment.ExitCode=0;}catch(Exception e){File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"self-test.txt"),"FAIL "+e.Message);Environment.ExitCode=1;}return;}
        bool created;using(var mutex=new Mutex(true,"Local\\WeChatGuardPrototype",out created)){if(!created){MessageBox.Show("微信离开保护已经在运行，请查看任务栏或托盘。");return;}Native.SetProcessDPIAware();Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);Application.Run(new GuardForm());}
    }
}
}
