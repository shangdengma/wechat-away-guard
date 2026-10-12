using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Threading.Tasks;
using System.Windows.Forms;
using System.Xml.Linq;

namespace WeChatGuard {
// The setup evidence expires; a saved device name alone never enables protection.
sealed class Profile {
    public string DeviceId="", DeviceName="", Fingerprint="";
    public DateTime VerifiedUtc=DateTime.MinValue;
    public int Delay=20;
    public bool Valid(DateTime now) { return DeviceId.Length>0 && VerifiedUtc<=now && (now-VerifiedUtc).TotalDays<7; }
    public static string FilePath { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"GlobeGuard","profile.xml"); } }
    public static Profile Load() {
        var p=new Profile();try { var x=XElement.Load(FilePath);p.DeviceId=(string)x.Element("device")??"";p.DeviceName=(string)x.Element("name")??"";p.Fingerprint=(string)x.Element("app")??"";
            p.VerifiedUtc=DateTime.Parse((string)x.Element("verified"),null,System.Globalization.DateTimeStyles.RoundtripKind).ToUniversalTime();
            p.Delay=Math.Max(10,Math.Min(180,(int?)x.Element("delay")??20));
        } catch { return new Profile(); } return p;
    }
    public void Save() { Directory.CreateDirectory(Path.GetDirectoryName(FilePath));var temp=FilePath+".tmp";
        new XElement("profile",new XElement("device",DeviceId),new XElement("name",DeviceName),new XElement("app",Fingerprint),new XElement("verified",VerifiedUtc.ToString("o")),new XElement("delay",Delay)).Save(temp);
        if(File.Exists(FilePath))File.Replace(temp,FilePath,null);else File.Move(temp,FilePath);
    }
}
sealed class SetupGate {
    public int Phase, Good;
    public double Deadline;
    double? lost;
    public SetupGate(double now) { Deadline=now+180; }
    // 0: on, 1: off, 2: same device back, 3: complete, -1: failed.
    public int Step(Signal signal,double now,int delay,bool radioReady) {
        if(Phase==3||Phase==-1)return Phase;
        if(!radioReady||now>Deadline){Phase=-1;return Phase;}
        if(Phase==1){
            if(signal==Signal.Present)lost=null;
            else {if(!lost.HasValue)lost=now;if(now-lost.Value>=delay){Phase=2;Good=0;Deadline=now+180;}}
        } else {
            Good=signal==Signal.Present?Good+1:0;
            if(Good>=2){Phase=Phase==0?1:3;Good=0;Deadline=now+180;}
        }
        return Phase;
    }
}
sealed class GuardForm : Form {
    static readonly Color Ink=Color.FromArgb(24,39,36),Green=Color.FromArgb(0,126,96),Muted=Color.FromArgb(100,116,111);
    Label status=new Label(),detail=new Label(),deviceLabel=new Label(),badge=new Label();
    Button primary=new Button(),settings=new Button();
    NotifyIcon tray=new NotifyIcon();
    TextBox log=new TextBox();
    Profile profile=Profile.Load();
    DeviceChoice selected;
    Presence presence=new Presence();
    SetupGate setup;
    Stopwatch clock=Stopwatch.StartNew();
    System.Windows.Forms.Timer timer=new System.Windows.Forms.Timer();
    bool running,busy,locking,closing,exitRequested,calibrated;
    int generation;
    public GuardForm() {
        SuspendLayout();
        Text="🌏 离开保护";ClientSize=new Size(720,560);
        AutoScaleMode=AutoScaleMode.None;Font=new Font("Microsoft YaHei UI",10);BackColor=Color.FromArgb(245,248,246);ForeColor=Ink;StartPosition=FormStartPosition.CenterScreen;
        Controls.Add(LabelAt("🌏  离开保护",26,24,410,40,19,true));
        Controls.Add(LabelAt("WINDOWS  /  体验版 0.3.1",465,36,230,24,9,false));
        Controls.Add(LabelAt("离开安心，回来继续。",28,83,640,40,24,true));
        Controls.Add(LabelAt("只锁 🌏，不锁电脑。返回后由你在手机上确认解锁。",30,133,660,30,10,false));
        var card=new Panel{Location=new Point(28,182),Size=new Size(664,208),BackColor=Color.White};Controls.Add(card);
        badge=LabelAt("● 尚未保护",24,18,610,25,10,true);card.Controls.Add(badge);
        status=LabelAt("连接你的 iPhone",24,53,610,42,21,true);card.Controls.Add(status);
        detail=LabelAt("首次用一次引导完成连接验证，以后可直接开启。",26,105,605,53,11,false);card.Controls.Add(detail);
        deviceLabel=LabelAt("无需在手机安装 App",26,172,610,25,10,false);card.Controls.Add(deviceLabel);
        primary.Text="开始设置";primary.Location=new Point(28,414);primary.Size=new Size(452,54);primary.FlatStyle=FlatStyle.Flat;primary.FlatAppearance.BorderSize=0;primary.BackColor=Green;primary.ForeColor=Color.White;primary.Font=new Font(Font.FontFamily,12,FontStyle.Bold);Controls.Add(primary);
        settings.Text="设置与诊断";settings.Location=new Point(496,414);settings.Size=new Size(196,54);settings.FlatStyle=FlatStyle.Flat;settings.FlatAppearance.BorderColor=Color.FromArgb(213,223,218);settings.BackColor=Color.White;Controls.Add(settings);
        Controls.Add(LabelAt("关闭窗口后留在托盘  ·  退出请右键托盘图标  ·  未开启开机自启",30,493,664,23,9,false));
        Controls.Add(LabelAt("蓝牙无法精确测距，首次使用请在工位实际验证。",30,522,664,23,9,false));
        log.Multiline=true;log.ReadOnly=true;log.ScrollBars=ScrollBars.Vertical;
        tray.Icon=SystemIcons.Shield;tray.Text="离开保护：尚未开启";tray.Visible=true;
        var menu=new ContextMenuStrip();menu.Items.Add("打开离开保护",null,delegate{ShowPanel();});menu.Items.Add("暂停保护",null,delegate{Stop();});menu.Items.Add("退出程序",null,delegate{Exit();});tray.ContextMenuStrip=menu;tray.DoubleClick+=delegate{ShowPanel();};
        primary.Click+=async delegate{await Primary();};settings.Click+=async delegate{await Settings();};
        timer.Interval=5000;timer.Tick+=async delegate{await Tick();};
        FormClosing+=delegate(object sender,FormClosingEventArgs e){if(!exitRequested){e.Cancel=true;Hide();return;}closing=true;timer.Stop();tray.Dispose();timer.Dispose();};
        if(profile.DeviceId.Length>0)selected=new DeviceChoice{Id=profile.DeviceId,Name=profile.DeviceName};
        calibrated=profile.Valid(DateTime.UtcNow);
        State(calibrated?"准备好了":"连接你的 iPhone",calibrated?"已记住你的手机。开启后自动检查连接，无需重复设置。":"首次完成手机识别与锁定验证，以后可直接开启。",false);
        FitDpi(this);ResumeLayout(true);
    }
    static void ScaleBounds(Control parent,float factor){foreach(Control c in parent.Controls){c.Bounds=new Rectangle((int)(c.Left*factor),(int)(c.Top*factor),(int)(c.Width*factor),(int)(c.Height*factor));ScaleBounds(c,factor);}}
    static void FitDpi(Form f){f.AutoScaleMode=AutoScaleMode.None;float factor;using(var g=f.CreateGraphics())factor=g.DpiX/96F;var client=f.ClientSize;f.MinimumSize=Size.Empty;f.MaximumSize=Size.Empty;if(factor!=1){ScaleBounds(f,factor);f.ClientSize=new Size((int)(client.Width*factor),(int)(client.Height*factor));}f.MinimumSize=f.Size;f.MaximumSize=f.Size;f.MaximizeBox=false;}
    Label LabelAt(string text,int x,int y,int w,int h,int size,bool bold){return new Label{Text=text,Location=new Point(x,y),Size=new Size(w,h),Font=new Font("Microsoft YaHei UI",size,bold?FontStyle.Bold:FontStyle.Regular),ForeColor=bold?Ink:Muted};}
    void ShowPanel(){Show();WindowState=FormWindowState.Normal;Activate();}
    void State(string title,string text,bool good){status.Text=title;detail.Text=text;badge.Text=good?"● 保护正在运行":(setup!=null?"● 首次设置 · 尚未保护":"● 尚未保护");badge.ForeColor=good?Green:Color.FromArgb(148,95,32);tray.Text="离开保护："+title;UpdateControls();}
    void UpdateControls(){if(closing)return;primary.Enabled=!locking&&(!busy||running||setup!=null);settings.Enabled=!running&&setup==null&&!busy&&!locking;
        primary.Text=locking?"正在验证锁定…":busy&&!running&&setup==null?"正在检查…":running?"暂停保护":setup!=null?"取消设置":calibrated?(profile.Fingerprint.Length>0?"开启保护":"验证锁定并开启"):"开始设置";
        primary.BackColor=running||setup!=null?Color.FromArgb(67,86,79):Green;
        deviceLabel.Text=selected==null?"无需在手机安装 App":selected.Name+"  ·  失联 "+profile.Delay+" 秒后触发";
    }
    void Note(string text){if(closing)return;log.AppendText(DateTime.Now.ToString("HH:mm:ss")+"  "+text+Environment.NewLine);if(log.TextLength>15000)log.Text=log.Text.Substring(log.TextLength-10000);}
    void Save(){try{profile.Save();}catch(Exception ex){Note("设置无法保存，下次可能需要重新设置："+ex.GetType().Name);}}
    void Stop(){if(locking)return;generation++;running=false;setup=null;timer.Stop();State("保护已暂停","不会继续自动锁定。已经锁定的应用仍需在手机上解锁。",false);Note("保护已暂停。");}
    void Exit(){if(locking){ShowPanel();return;}if((running||setup!=null)&&MessageBox.Show("退出后将不再保护，确定退出？","退出离开保护",MessageBoxButtons.YesNo,MessageBoxIcon.Question)!=DialogResult.Yes)return;Stop();exitRequested=true;Close();}
    async Task<bool> ChoosePhone(){
        busy=true;UpdateControls();try{
            var list=await Phone.List();if(closing)return false;
            using(var f=new Form{Text="选择你的 iPhone",ClientSize=new Size(520,238),Font=Font,StartPosition=FormStartPosition.CenterParent,FormBorderStyle=FormBorderStyle.FixedDialog,MaximizeBox=false,MinimizeBox=false}){
                var text=LabelAt("手机放在电脑旁边，并保持蓝牙开启。",22,20,478,30,11,true);f.Controls.Add(text);
                var combo=new ComboBox{Location=new Point(24,62),Size=new Size(472,32),DropDownStyle=ComboBoxStyle.DropDownList};foreach(var d in list)combo.Items.Add(d);f.Controls.Add(combo);
                for(int i=0;i<combo.Items.Count;i++)if(((DeviceChoice)combo.Items[i]).Id==profile.DeviceId)combo.SelectedIndex=i;
                f.Controls.Add(LabelAt(list.Count==0?"没有已配对设备，请先到系统蓝牙设置配对。":"请确认手机名称。后续引导会验证是不是这部手机。",22,109,478,45,10,false));
                var pair=new Button{Text="系统蓝牙设置",Location=new Point(24,172),Size=new Size(166,40)};pair.Click+=delegate{try{Process.Start("ms-settings:bluetooth");}catch{} };f.Controls.Add(pair);
                var next=new Button{Text="下一步",Location=new Point(328,172),Size=new Size(168,40),DialogResult=DialogResult.OK,Enabled=combo.SelectedItem!=null};combo.SelectedIndexChanged+=delegate{next.Enabled=combo.SelectedItem!=null;};f.Controls.Add(next);f.AcceptButton=next;
                FitDpi(f);if(f.ShowDialog(this)!=DialogResult.OK)return false;
                selected=(DeviceChoice)combo.SelectedItem;profile.DeviceId=selected.Id;profile.DeviceName=selected.Name;profile.VerifiedUtc=DateTime.MinValue;profile.Fingerprint="";calibrated=false;Save();return true;
            }
        }catch(Exception ex){State("暂时无法连接",ex.Message,false);return false;}finally{busy=false;UpdateControls();}
    }
    async Task Primary(){
        if(locking)return;if(running||setup!=null){Stop();return;}if(busy)return;
        if(!calibrated||!profile.Valid(DateTime.UtcNow)){
            calibrated=false;if(!await ChoosePhone())return;setup=new SetupGate(clock.Elapsed.TotalSeconds);generation++;State("1 / 3  确认手机连接","让 iPhone 靠近电脑并打开蓝牙，程序会自动继续。",false);timer.Start();await Tick();return;
        }
        busy=true;UpdateControls();
        try{
            var target=Native.Find();
            if(profile.Fingerprint!=target.Fingerprint){
                // Explicit primary-button action gives context for the one-time lock test.
                if(MessageBox.Show("首次启用或应用更新后，需要验证一次锁定。\n接下来会锁定 🌏，其他软件不受影响。\n通过后自动开启保护；需要时请在手机上解锁。","完成最后一步",MessageBoxButtons.OKCancel,MessageBoxIcon.Information)!=DialogResult.OK)return;
                var phone=await Phone.Check(selected.Id);if(phone.Signal!=Signal.Present){State("请将手机放在旁边","还没有收到有效连接，保持手机蓝牙开启后再试。",false);return;}
                locking=true;UpdateControls();var result=await WeChat.Lock(null);locking=false;Note(result.Note);
                bool verified=result.Verified;
                if(!verified&&result.Sent)verified=MessageBox.Show("请查看 🌏 是否明确显示已锁定、需要手机解锁。\n确实锁定才选择“是”。","核实锁定结果",MessageBoxButtons.YesNo,MessageBoxIcon.Question)==DialogResult.Yes;
                if(!verified){profile.Fingerprint="";Save();State("还没有完成锁定验证",result.Note,false);return;}
                profile.Fingerprint=result.Fingerprint;Save();
            }
            generation++;presence=new Presence();running=true;State("正在确认手机在旁边","连续收到两次有效连接后开启保护，请稍候。",false);Note("开始真实保护；不是演练模式。");timer.Start();
        }catch(Exception ex){State("暂时无法开启",ex.Message,false);}finally{busy=false;locking=false;UpdateControls();}
        if(running)await Tick();
    }
    async Task Tick(){
        if((!running&&setup==null)||busy||locking||selected==null)return;int token=generation;busy=true;UpdateControls();
        try{
            bool radio=true;if(setup!=null)radio=await Phone.RadioReady();
            var result=radio?await Phone.Check(selected.Id):new ProbeResult(Signal.Unknown,"电脑蓝牙不可用");
            if(closing||token!=generation)return;Note(result.Note);
            if(setup!=null){
                int phase=setup.Step(result.Signal,clock.Elapsed.TotalSeconds,profile.Delay,radio);
                if(phase==-1){Stop();State("连接验证未完成",radio?"等待超时。请检查选中的手机，再重新设置。":"电脑蓝牙已关闭或不可用。请恢复后重新设置。",false);}
                else if(phase==0)State("1 / 3  确认手机连接","手机放在电脑旁边，保持蓝牙开启，等待自动确认。",false);
                else if(phase==1)State("2 / 3  关闭手机蓝牙","在 iPhone「设置 → 蓝牙」中关闭蓝牙，先不要打开。\n等页面提示“重新打开手机蓝牙”后再开启。电脑蓝牙保持开启。",false);
                else if(phase==2)State("3 / 3  重新打开手机蓝牙","已确认信号消失。请重新打开 iPhone 蓝牙，等待同一手机恢复。",false);
                else {setup=null;timer.Stop();calibrated=true;profile.VerifiedUtc=DateTime.UtcNow;Save();State("手机已确认","最后一步会锁定一次 🌏。点击下方按钮，验证后自动开启保护。",false);}
                return;
            }
            bool trigger=presence.Step(result.Signal,clock.Elapsed.TotalSeconds,profile.Delay);
            if(trigger){locking=true;UpdateControls();var locked=await WeChat.Lock(profile.Fingerprint);locking=false;if(closing||token!=generation)return;Note(locked.Note);
                if(locked.Verified){State("🌏 已锁定","其他软件正常使用。返回后请在手机上确认解锁。",true);tray.ShowBalloonTip(5000,"🌏 已锁定","离开保护已触发。",ToolTipIcon.Info);}
                else{profile.Fingerprint="";Save();Stop();State("请核实锁定结果",locked.Note+"；保护已暂停。",false);tray.ShowBalloonTip(8000,"保护已暂停",locked.Note,ToolTipIcon.Warning);}
            } else if(presence.Latched){}
            else if(result.Signal==Signal.Present)State(presence.Armed?"保护已开启":"正在确认手机连接",presence.Armed?"手机离开且持续失联后，将自动锁定 🌏。":"等待第二次有效连接，尚未开启保护。",presence.Armed);
            else if(presence.Armed){int left=Math.Max(0,profile.Delay-(int)(clock.Elapsed.TotalSeconds-presence.Lost.Value));State("手机信号中断","若持续失联，约 "+left+" 秒后尝试锁定。",true);}
            else State("等待手机连接","请将手机放在旁边并打开蓝牙，连接确认前尚未保护。",false);
        }catch(Exception ex){if(!closing&&token==generation){locking=false;Stop();State("保护暂时中断",ex.Message,false);}}finally{busy=false;locking=false;UpdateControls();}
    }
    async Task Settings(){
        bool reconnect=false;
        using(var f=new Form{Text="设置与诊断",ClientSize=new Size(600,425),Font=Font,StartPosition=FormStartPosition.CenterParent,FormBorderStyle=FormBorderStyle.FixedDialog,MaximizeBox=false,MinimizeBox=false}){
            f.Controls.Add(LabelAt("离开延时",22,20,160,30,12,true));var value=new NumericUpDown{Location=new Point(193,20),Size=new Size(90,30),Minimum=10,Maximum=180,Increment=5,Value=profile.Delay};f.Controls.Add(value);f.Controls.Add(LabelAt("秒（不等于距离）",294,23,275,30,10,false));
            f.Controls.Add(LabelAt("当前手机："+(selected==null?"未设置":selected.Name),22,67,554,30,10,false));
            var change=new Button{Text="更换手机／重新验证",Location=new Point(24,107),Size=new Size(235,38)};change.Click+=delegate{reconnect=true;f.Close();};f.Controls.Add(change);
            f.Controls.Add(LabelAt("连接验证保留 7 天；换手机或应用更新后重新验证。",22,154,554,28,10,false));
            var box=new TextBox{Text=log.Text,Multiline=true,ReadOnly=true,ScrollBars=ScrollBars.Vertical,Location=new Point(24,190),Size=new Size(552,150)};f.Controls.Add(box);
            var save=new Button{Text="保存",Location=new Point(416,362),Size=new Size(160,40),DialogResult=DialogResult.OK};f.Controls.Add(save);
            FitDpi(f);if(f.ShowDialog(this)==DialogResult.OK){profile.Delay=(int)value.Value;Save();UpdateControls();}
        }
        if(reconnect){profile.VerifiedUtc=DateTime.MinValue;profile.Fingerprint="";calibrated=false;Save();await Primary();}
    }
}
}
