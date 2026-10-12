#import <Cocoa/Cocoa.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <ApplicationServices/ApplicationServices.h>
#import <JavaScriptCore/JavaScriptCore.h>

static double Now(void) { return NSProcessInfo.processInfo.systemUptime; }
static id Attribute(AXUIElementRef element, CFStringRef key) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, key, &value) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(value);
}
static NSString *Normalize(NSString *s) {
    return [[s componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsJoinedByString:@""].lowercaseString;
}
// Traverse bounded accessibility trees; never store window text or chat content.
static void FindMenu(AXUIElementRef element, NSMutableArray *hits, int depth, int *budget) {
    if (depth > 7 || --*budget < 0) return;
    NSString *role = Attribute(element, kAXRoleAttribute);
    NSString *title = Attribute(element, kAXTitleAttribute);
    NSArray *names = @[@"锁定", @"鎖定", @"锁定微信", @"鎖定微信", @"Lock", @"Lock WeChat"];
    if ([role isEqualToString:(__bridge NSString *)kAXMenuItemRole] && [names containsObject:title ?: @""] && [Attribute(element, kAXEnabledAttribute) boolValue]) {
        [hits addObject:(__bridge id)element];
    }
    id children = Attribute(element, kAXChildrenAttribute);
    if ([children isKindOfClass:NSArray.class]) for (id child in children) FindMenu((__bridge AXUIElementRef)child, hits, depth+1, budget);
}
static BOOL HasLockText(AXUIElementRef element, int depth, int *budget) {
    if (depth > 9 || --*budget < 0) return NO;
    for (NSString *key in @[(__bridge NSString *)kAXTitleAttribute, (__bridge NSString *)kAXValueAttribute, (__bridge NSString *)kAXDescriptionAttribute]) {
        id value = Attribute(element, (__bridge CFStringRef)key);
        if (![value isKindOfClass:NSString.class]) continue;
        NSString *s = Normalize(value);
        for (NSString *needle in @[@"Mac 微信已被锁定", @"Mac 微信已锁定", @"Mac 微信已鎖定", @"WeChat for Mac is locked", @"WeChat for Mac has been locked"]) {
            if ([s isEqualToString:Normalize(needle)]) return YES;
        }
    }
    id children=Attribute(element,kAXChildrenAttribute);
    if ([children isKindOfClass:NSArray.class]) for(id child in children) if(HasLockText((__bridge AXUIElementRef)child,depth+1,budget))return YES;
    return NO;
}

@interface Guard : NSObject <NSApplicationDelegate, CBCentralManagerDelegate, CBPeripheralDelegate, NSWindowDelegate>
@property(nonatomic,strong) NSWindow *window;
@property(nonatomic,strong) NSWindow *settingsWindow;
@property(nonatomic,strong) NSStackView *setupView;
@property(nonatomic,copy) NSString *savedDevice;
@property BOOL continueSetup;

@property(nonatomic,strong) NSStatusItem *tray;
@property(nonatomic,strong) NSTextField *headline, *detail, *modeLabel, *rssiLabel;
@property(nonatomic,strong) NSPopUpButton *picker;
@property(nonatomic,strong) NSButton *scanButton, *calibrateButton, *lockButton, *startButton, *stopButton, *weak;
@property(nonatomic,strong) NSSlider *delaySlider, *rssiSlider;
@property(nonatomic,strong) NSTextView *log;
@property(nonatomic,strong) CBCentralManager *central;
@property(nonatomic,strong) NSMutableDictionary<NSUUID *, CBPeripheral *> *devices;
@property(nonatomic,strong) NSMutableDictionary<NSUUID *, NSNumber *> *lastPackets;
@property(nonatomic,strong) NSMutableDictionary<NSUUID *, NSString *> *names;
@property(nonatomic,strong) CBPeripheral *target;
@property(nonatomic,strong) JSContext *js;
@property(nonatomic,strong) JSValue *engine;
@property(nonatomic,strong) NSTimer *timer;
@property BOOL monitoring, calibrating, lockBusy, calibrated;
@property NSInteger calibrationPhase;
@property double calibrationDeadline, lastRssiRequest, lastConnect, lastLog;
@property(nonatomic,copy) NSString *testedWeChat;
@end

@implementation Guard
- (NSTextField *)label:(NSString *)text size:(CGFloat)size bold:(BOOL)bold {
    NSTextField *l=[NSTextField wrappingLabelWithString:text];
    l.font=bold?[NSFont boldSystemFontOfSize:size]:[NSFont systemFontOfSize:size];
    l.preferredMaxLayoutWidth=710; return l;
}
- (NSButton *)button:(NSString *)title action:(SEL)action { return [NSButton buttonWithTitle:title target:self action:action]; }
- (NSStackView *)row:(NSArray<NSView *> *)views {
    NSStackView *v=[NSStackView stackViewWithViews:views];v.orientation=NSUserInterfaceLayoutOrientationHorizontal;v.spacing=12;v.alignment=NSLayoutAttributeCenterY;return v;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.devices=[NSMutableDictionary dictionary];self.lastPackets=[NSMutableDictionary dictionary];self.names=[NSMutableDictionary dictionary];
    self.js=[JSContext new];
    NSString *core=[NSString stringWithContentsOfURL:[NSBundle.mainBundle URLForResource:@"guard-core" withExtension:@"js"] encoding:NSUTF8StringEncoding error:nil];
    if(!core){[self alert:@"缺少状态机资源，请重新构建程序。"];[NSApp terminate:nil];return;}
    [self.js evaluateScript:core];
    if(self.js.exception){[self alert:@"状态机加载失败，未开启任何保护。"];[NSApp terminate:nil];return;}
    NSUserDefaults *prefs=NSUserDefaults.standardUserDefaults;
    self.savedDevice=[prefs stringForKey:@"device"];
    self.testedWeChat=[prefs stringForKey:@"app"];
    self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,700,590) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
    self.window.title=@"🌏 离开保护";self.window.delegate=self;[self.window center];
    NSStackView *stack=[NSStackView new];stack.orientation=NSUserInterfaceLayoutOrientationVertical;stack.alignment=NSLayoutAttributeLeading;stack.spacing=20;stack.translatesAutoresizingMaskIntoConstraints=NO;
    [self.window.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:self.window.contentView.leadingAnchor constant:30],[stack.trailingAnchor constraintEqualToAnchor:self.window.contentView.trailingAnchor constant:-30],[stack.topAnchor constraintEqualToAnchor:self.window.contentView.topAnchor constant:26],[stack.bottomAnchor constraintLessThanOrEqualToAnchor:self.window.contentView.bottomAnchor constant:-20]]];
    [stack addArrangedSubview:[self label:@"🌏 离开保护                         Mac 体验版 0.2" size:18 bold:YES]];
    [stack addArrangedSubview:[self label:@"离开安心，回来继续。" size:30 bold:YES]];
    [stack addArrangedSubview:[self label:@"只锁 🌏，不锁电脑。返回后由你在手机上确认解锁。" size:13 bold:NO]];
    self.headline=[self label:@"尚未开启保护" size:23 bold:YES];[stack addArrangedSubview:self.headline];
    self.detail=[self label:@"首次完成手机识别与锁定验证，以后可直接开启。" size:14 bold:NO];[self.detail.heightAnchor constraintGreaterThanOrEqualToConstant:48].active=YES;[stack addArrangedSubview:self.detail];
    self.setupView=[NSStackView new];self.setupView.orientation=NSUserInterfaceLayoutOrientationVertical;self.setupView.alignment=NSLayoutAttributeLeading;self.setupView.spacing=10;
    self.picker=[NSPopUpButton new];[self.picker addItemWithTitle:@"选择你的 iPhone"];self.picker.target=self;self.picker.action=@selector(selectDevice:);[self.picker.widthAnchor constraintEqualToConstant:450].active=YES;
    self.scanButton=[self button:@"重新扫描" action:@selector(scan:)];[self.setupView addArrangedSubview:[self row:@[self.picker,self.scanButton]]];
    [self.setupView addArrangedSubview:[self label:@"名称仅供识别，接下来会引导验证是不是你的手机。" size:12 bold:NO]];
    [stack addArrangedSubview:self.setupView];self.setupView.hidden=YES;
    self.rssiLabel=[self label:@"无需在 iPhone 安装 App" size:12 bold:NO];[stack addArrangedSubview:self.rssiLabel];
    self.startButton=[self button:@"开始设置" action:@selector(start:)];self.startButton.bezelStyle=NSBezelStyleRounded;self.startButton.controlSize=NSControlSizeLarge;self.startButton.bezelColor=[NSColor colorWithCalibratedRed:0 green:0.50 blue:0.37 alpha:1];[self.startButton.widthAnchor constraintEqualToConstant:380].active=YES;
    [stack addArrangedSubview:[self row:@[self.startButton,[self button:@"设置与诊断" action:@selector(showSettings:)]]]];
    [stack addArrangedSubview:[self label:@"关闭窗口后留在菜单栏 · 未开启开机自启\n蓝牙无法精确测距，请在工位实际验证。" size:12 bold:NO]];
    // Technical controls live in a separate window; the home screen is always real protection.
    self.settingsWindow=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,660,460) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];self.settingsWindow.title=@"设置与诊断";self.settingsWindow.releasedWhenClosed=NO;
    NSStackView *options=[NSStackView new];options.orientation=NSUserInterfaceLayoutOrientationVertical;options.alignment=NSLayoutAttributeLeading;options.spacing=16;options.translatesAutoresizingMaskIntoConstraints=NO;[self.settingsWindow.contentView addSubview:options];
    [NSLayoutConstraint activateConstraints:@[[options.leadingAnchor constraintEqualToAnchor:self.settingsWindow.contentView.leadingAnchor constant:24],[options.trailingAnchor constraintEqualToAnchor:self.settingsWindow.contentView.trailingAnchor constant:-24],[options.topAnchor constraintEqualToAnchor:self.settingsWindow.contentView.topAnchor constant:24]]];
    NSInteger savedDelay=[prefs integerForKey:@"delay"];
    self.delaySlider=[NSSlider sliderWithValue:savedDelay>=10&&savedDelay<=90?savedDelay:20 minValue:10 maxValue:90 target:self action:@selector(settingsChanged:)];[self.delaySlider.widthAnchor constraintEqualToConstant:240].active=YES;
    [options addArrangedSubview:[self row:@[[self label:@"离开延时" size:13 bold:NO],self.delaySlider]]];
    self.weak=[NSButton checkboxWithTitle:@"高级：信号变弱也触发" target:self action:@selector(settingsChanged:)];self.weak.state=[prefs boolForKey:@"weak"]?NSControlStateValueOn:NSControlStateValueOff;
    self.rssiSlider=[NSSlider sliderWithValue:[prefs objectForKey:@"threshold"]?[prefs doubleForKey:@"threshold"]:-80 minValue:-100 maxValue:-45 target:self action:@selector(settingsChanged:)];[self.rssiSlider.widthAnchor constraintEqualToConstant:220].active=YES;[options addArrangedSubview:[self row:@[self.weak,self.rssiSlider]]];

    self.modeLabel=[self label:@"" size:13 bold:NO];[options addArrangedSubview:self.modeLabel];
    self.calibrateButton=[self button:@"更换手机／重新验证" action:@selector(resetSetup:)];[options addArrangedSubview:[self row:@[self.calibrateButton,[self button:@"系统权限…" action:@selector(permission:)]]]];
    [options addArrangedSubview:[self label:@"连接验证保留 7 天；换手机后重新引导。" size:12 bold:NO]];
    NSScrollView *scroll=[NSScrollView new];scroll.hasVerticalScroller=YES;scroll.borderType=NSBezelBorder;[scroll.widthAnchor constraintEqualToConstant:600].active=YES;[scroll.heightAnchor constraintEqualToConstant:155].active=YES;
    self.log=[[NSTextView alloc] initWithFrame:NSMakeRect(0,0,590,155)];self.log.editable=NO;self.log.font=[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];self.log.autoresizingMask=NSViewWidthSizable;scroll.documentView=self.log;[options addArrangedSubview:scroll];
    self.tray=[[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];self.tray.button.title=@"🌏";
    NSMenu *menu=[NSMenu new];for(NSArray *item in @[@[@"打开离开保护",NSStringFromSelector(@selector(show:))],@[@"暂停保护",NSStringFromSelector(@selector(stop:))],@[@"退出程序",NSStringFromSelector(@selector(quit:))]]){NSMenuItem *m=[[NSMenuItem alloc]initWithTitle:item[0] action:NSSelectorFromString(item[1]) keyEquivalent:@""];m.target=self;[menu addItem:m];}self.tray.menu=menu;
    [self settingsChanged:nil];[self updateControls];
    self.central=[[CBCentralManager alloc] initWithDelegate:self queue:dispatch_get_main_queue() options:@{CBCentralManagerOptionShowPowerAlertKey:@YES}];
    self.timer=[NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [NSApp activateIgnoringOtherApps:YES];[self.window makeKeyAndOrderFront:nil];
}
- (void)alert:(NSString *)message { NSAlert *a=[NSAlert new];a.messageText=message;[a addButtonWithTitle:@"确定"];[a runModal]; }
- (void)note:(NSString *)text { NSDateFormatter *f=[NSDateFormatter new];f.dateFormat=@"HH:mm:ss";NSString *line=[NSString stringWithFormat:@"%@  %@\n",[f stringFromDate:NSDate.date],text];[self.log.textStorage appendAttributedString:[[NSAttributedString alloc]initWithString:line]];if(self.log.string.length>16000)[self.log.textStorage deleteCharactersInRange:NSMakeRange(0,6000)];[self.log scrollRangeToVisible:NSMakeRange(self.log.string.length,0)]; }
- (void)state:(NSString *)title detail:(NSString *)detail {self.headline.stringValue=title;self.detail.stringValue=detail;self.tray.button.toolTip=title;}
- (BOOL)calibrationFresh { NSDate *date=[NSUserDefaults.standardUserDefaults objectForKey:@"verified"];double age=[date isKindOfClass:NSDate.class]?-date.timeIntervalSinceNow:-1;return age>=0&&age<7*86400&&self.target&&[self.target.identifier.UUIDString isEqualToString:self.savedDevice]; }
- (void)saveProfile {NSUserDefaults *p=NSUserDefaults.standardUserDefaults;if(self.target){self.savedDevice=self.target.identifier.UUIDString;[p setObject:self.savedDevice forKey:@"device"];}if(self.testedWeChat)[p setObject:self.testedWeChat forKey:@"app"];else [p removeObjectForKey:@"app"];[p setInteger:self.delaySlider.integerValue forKey:@"delay"];[p setBool:self.weak.state==NSControlStateValueOn forKey:@"weak"];[p setDouble:self.rssiSlider.doubleValue forKey:@"threshold"];}
- (void)updateControls {BOOL idle=!self.monitoring&&!self.calibrating&&!self.lockBusy;self.picker.enabled=self.scanButton.enabled=self.calibrateButton.enabled=self.delaySlider.enabled=self.weak.enabled=idle;self.rssiSlider.enabled=idle&&self.weak.state==NSControlStateValueOn;self.startButton.enabled=!self.lockBusy;self.startButton.title=self.lockBusy?@"正在验证锁定…":self.monitoring?@"暂停保护":self.calibrating?@"取消设置":[self calibrationFresh]?@"开启保护":self.target?@"继续设置":@"开始设置";}
- (void)settingsChanged:(id)sender {if(sender){if(sender==self.weak||sender==self.rssiSlider){self.calibrated=NO;[NSUserDefaults.standardUserDefaults removeObjectForKey:@"verified"];}[self saveProfile];}self.modeLabel.stringValue=[NSString stringWithFormat:@"自动保护 · 延时 %ld 秒 · %@",(long)self.delaySlider.integerValue,self.weak.state==NSControlStateValueOn?[NSString stringWithFormat:@"弱信号 %ld dBm",(long)self.rssiSlider.integerValue]:@"仅信号消失触发"];[self updateControls];}
- (void)showSettings:(id)sender {[self.settingsWindow center];[self.settingsWindow makeKeyAndOrderFront:nil];}
- (void)resetSetup:(id)sender {if(self.monitoring||self.calibrating||self.lockBusy)return;[NSUserDefaults.standardUserDefaults removeObjectForKey:@"verified"];self.calibrated=NO;self.testedWeChat=nil;self.continueSetup=NO;if(self.target&&self.target.state!=CBPeripheralStateDisconnected)[self.central cancelPeripheralConnection:self.target];self.target=nil;self.savedDevice=nil;[NSUserDefaults.standardUserDefaults removeObjectForKey:@"device"];[self saveProfile];[self.picker selectItemAtIndex:0];[self.settingsWindow orderOut:nil];self.setupView.hidden=NO;[self show:nil];[self scan:nil];[self state:@"选择你的 iPhone" detail:@"手机放在电脑旁边，选择后点击继续设置。"];[self updateControls];}
- (void)newEngineCalibration:(BOOL)calibration {id threshold=(!calibration&&self.weak.state==NSControlStateValueOn)?@(self.rssiSlider.integerValue):NSNull.null;self.engine=[self.js[@"GuardCore"][@"Engine"] constructWithArguments:@[@(self.delaySlider.integerValue),@10,threshold]];}
- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    if(central.state!=CBManagerStatePoweredOn){[self note:@"Mac 蓝牙不可用或权限未授予。"];if(self.calibrating){[self stop:nil];[self state:@"设置已暂停" detail:@"请保持 Mac 蓝牙开启，再重新验证手机。"];}else if(!self.monitoring)[self state:@"蓝牙尚未就绪" detail:@"请在系统设置中打开蓝牙并允许本程序使用蓝牙。"];return;}
    if(!self.target&&self.savedDevice){NSUUID *identifier=[[NSUUID alloc]initWithUUIDString:self.savedDevice];NSArray *known=identifier?[central retrievePeripheralsWithIdentifiers:@[identifier]]:@[];self.target=known.firstObject;self.target.delegate=self;self.calibrated=[self calibrationFresh];if(self.target)[self state:@"准备好了" detail:@"已记住你的手机。开启后会重新确认实时连接。"];}
    [self updateControls];
}
- (void)scan:(id)sender {if(self.central.state!=CBManagerStatePoweredOn){[self alert:@"Mac 蓝牙未就绪，请检查蓝牙开关和权限。"];return;}[self.central scanForPeripheralsWithServices:nil options:@{CBCentralManagerScanOptionAllowDuplicatesKey:@YES}];[self note:@"正在接收实时广播；请将 iPhone 放在 Mac 旁边。"];}
- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)p advertisementData:(NSDictionary<NSString *,id> *)ad RSSI:(NSNumber *)RSSI {
    NSString *name=ad[CBAdvertisementDataLocalNameKey]?:p.name?:@"未命名蓝牙设备";
    self.devices[p.identifier]=p;self.lastPackets[p.identifier]=@(Now());self.names[p.identifier]=name;
    if([self.picker indexOfItemWithRepresentedObject:p.identifier]==-1){
        if(self.picker.numberOfItems<100){NSString *shortId=[p.identifier.UUIDString substringFromIndex:30];[self.picker addItemWithTitle:[NSString stringWithFormat:@"%@ · %@",name,shortId]];self.picker.lastItem.representedObject=p.identifier;}
    }
    if([p.identifier isEqual:self.target.identifier])[self observed:RSSI];
}
- (void)selectDevice:(id)sender {NSUUID *identifier=self.picker.selectedItem.representedObject;if(self.target&&self.target.state!=CBPeripheralStateDisconnected)[self.central cancelPeripheralConnection:self.target];self.target=identifier?self.devices[identifier]:nil;self.target.delegate=self;self.calibrated=NO;[NSUserDefaults.standardUserDefaults removeObjectForKey:@"verified"];self.engine=nil;self.lastConnect=0;[self state:@"手机已选择" detail:@"点击继续设置，按提示完成一次蓝牙开关验证。"];[self updateControls];}
- (void)observed:(NSNumber *)RSSI {if(!RSSI||RSSI.integerValue>=0||RSSI.integerValue< -127)return;self.rssiLabel.stringValue=@"已收到所选手机的新信号";if(self.engine)[self.engine invokeMethod:@"observe" withArguments:@[@(Now()),RSSI]];if(Now()-self.lastLog>5){[self note:[NSString stringWithFormat:@"收到选定设备的新蓝牙信号：%@ dBm",RSSI]];self.lastLog=Now();}}
- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)p {if(p!=self.target)return;p.delegate=self;[self note:@"蓝牙连接已建立；等待实时 RSSI，不把连接状态当作在线证据。"];[p readRSSI];}
- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)p error:(NSError *)error {if(p==self.target)[self note:@"主动连接失败，继续等待新广播；没有新信号会进入失联判断。"];}
- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)p error:(NSError *)error {if(p==self.target)[self note:@"蓝牙连接断开，等待新广播或重连。"];}
- (void)peripheral:(CBPeripheral *)p didReadRSSI:(NSNumber *)RSSI error:(NSError *)error {if(p==self.target&&!error)[self observed:RSSI];}
- (void)calibrate:(id)sender {if(!self.target){[self alert:@"请先扫描并选择设备。"];return;}if(self.central.state!=CBManagerStatePoweredOn){[self alert:@"请先打开 Mac 蓝牙。"];return;}self.calibrated=NO;[NSUserDefaults.standardUserDefaults removeObjectForKey:@"verified"];self.calibrating=YES;self.setupView.hidden=YES;self.calibrationPhase=0;self.calibrationDeadline=Now()+180;[self newEngineCalibration:YES];[self scan:nil];[self state:@"校验 1/3：等待手机开启蓝牙" detail:@"手机放在 Mac 旁边，保持蓝牙开启。等待至少两次新信号。"];[self updateControls];}
- (NSArray<NSRunningApplication *> *)wechatApps {return [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.tencent.xinWeChat"];}
- (NSString *)fingerprint:(NSRunningApplication *)app {NSBundle *b=[NSBundle bundleWithURL:app.bundleURL];return [NSString stringWithFormat:@"%@|%@",app.bundleURL.path,[b objectForInfoDictionaryKey:@"CFBundleVersion"]?:@"unknown"];}
- (void)permission:(id)sender {NSDictionary *options=@{(__bridge NSString *)kAXTrustedCheckOptionPrompt:@YES};AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);[self alert:@"请在系统设置 → 隐私与安全性 → 辅助功能中允许 WeChatGuard。蓝牙权限也由你在系统弹窗中确认。完成后回来测试。"];}
- (void)testLock:(id)sender {[self lockWeChat:YES];}
- (void)lockWeChat:(BOOL)test {
    if(self.lockBusy)return;
    if(!AXIsProcessTrusted()){[self state:@"需要辅助功能权限" detail:@"点击“辅助功能权限…”并在系统设置授权，然后重新测试。"];if(!test)[self stop:nil];return;}
    NSArray *apps=[self wechatApps];if(apps.count!=1){[self state:@"请打开一个 🌏 主窗口" detail:@"请登录应用并打开主窗口，目前不支持多开。"];if(!test)[self stop:nil];return;}
    NSRunningApplication *app=apps.firstObject;NSString *finger=[self fingerprint:app];
    if(!test&&![finger isEqualToString:self.testedWeChat]){[self stop:nil];[self state:@"微信已变化，需要重测" detail:@"请重新点击测试锁定微信。"];return;}
    self.lockBusy=YES;[self updateControls];[app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        AXUIElementRef ax=AXUIElementCreateApplication(app.processIdentifier);AXUIElementSetMessagingTimeout(ax,2.0);
        id bar=Attribute(ax,kAXMenuBarAttribute);NSMutableArray *hits=[NSMutableArray array];int budget=250;
        if(bar)FindMenu((__bridge AXUIElementRef)bar,hits,0,&budget);
        AXError outcome=kAXErrorFailure;
        if(hits.count==1)outcome=AXUIElementPerformAction((__bridge AXUIElementRef)hits.firstObject,kAXPressAction);
        CFRelease(ax);
        if(outcome!=kAXErrorSuccess){self.lockBusy=NO;if(!test)[self stop:nil];[self state:@"未能执行微信原生锁定" detail:@"未找到唯一可用的锁定菜单，或微信拒绝操作。未发送猜测快捷键；需要适配此微信版本。"];[self note:@"锁定失败，不能视为已保护。"];[self updateControls];return;}
        [self note:@"已调用微信原生锁定菜单，正在检查结果。"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,1800*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            AXUIElementRef check=AXUIElementCreateApplication(app.processIdentifier);AXUIElementSetMessagingTimeout(check,1.0);int remaining=180;BOOL verified=NO;
            id windows=Attribute(check,kAXWindowsAttribute);if([windows isKindOfClass:NSArray.class])for(id w in windows)if(HasLockText((__bridge AXUIElementRef)w,0,&remaining)){verified=YES;break;}CFRelease(check);
            self.lockBusy=NO;
            if(test&&!verified){[NSApp activateIgnoringOtherApps:YES];[self.window makeKeyAndOrderFront:nil];NSAlert *a=[NSAlert new];a.messageText=@"请核实微信是否真的锁定";a.informativeText=@"程序无法自动识别锁定提示。只有微信明确显示已锁定、需要手机解锁时，才点击“确实已锁定”。";[a addButtonWithTitle:@"尚未确认"];[a addButtonWithTitle:@"确实已锁定"];verified=[a runModal]==NSAlertSecondButtonReturn;}
            if(verified){if(test){self.testedWeChat=finger;[self saveProfile];}[self state:test?@"锁定验证通过":@"🌏 已锁定" detail:@"回来后请在手机微信确认解锁；工具不会自动解锁。"];[self note:@"微信锁定结果已确认。"];}
            else {if(test){self.testedWeChat=nil;[self saveProfile];}else [self stop:nil];[self state:@"锁定结果未确认" detail:@"请查看微信；未确认时不能视为已保护，自动监测已暂停。"];[self note:@"锁定结果未确认。"];}
            [self updateControls];if(test&&verified&&self.continueSetup)[self start:nil];
        });
    });
}
- (void)start:(id)sender {
    if(self.lockBusy)return;if(self.monitoring||self.calibrating){[self stop:nil];return;}
    if(self.central.state!=CBManagerStatePoweredOn){[self state:@"蓝牙尚未就绪" detail:@"请打开 Mac 蓝牙并授予蓝牙权限，然后继续。"];return;}
    if(!self.target){self.setupView.hidden=NO;[self scan:nil];[self state:@"选择你的 iPhone" detail:@"手机放在电脑旁边，选择后点击继续设置。"];return;}
    self.continueSetup=YES;
    if(![self calibrationFresh]){[self calibrate:nil];return;}
    if(!AXIsProcessTrusted()){NSDictionary *options=@{(__bridge NSString *)kAXTrustedCheckOptionPrompt:@YES};AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);[self state:@"最后一步：允许锁定操作" detail:@"在系统设置 → 隐私与安全性 → 辅助功能中允许 WeChatGuard，回来点击开启保护。"];return;}
    NSArray *apps=[self wechatApps];if(apps.count!=1){[self state:@"请先打开并登录 🌏" detail:@"打开一个账号主窗口后，再点击开启保护。"];return;}
    if(![[self fingerprint:apps.firstObject] isEqualToString:self.testedWeChat]){NSAlert *a=[NSAlert new];a.messageText=@"验证一次锁定，即可开启保护";a.informativeText=@"接下来将锁定一次 🌏，通过后自动开始保护。返回使用请在手机上解锁。";[a addButtonWithTitle:@"验证并开启"];[a addButtonWithTitle:@"稍后"];if([a runModal]==NSAlertFirstButtonReturn)[self lockWeChat:YES];return;}
    self.continueSetup=NO;self.monitoring=YES;self.setupView.hidden=YES;[self newEngineCalibration:NO];[self scan:nil];[self note:@"开始真实保护；不是演练模式。"];[self state:@"正在确认手机连接" detail:@"连续收到两次新信号后开启保护，请稍候。"];[self updateControls];
}
- (void)stop:(id)sender {if(self.lockBusy)return;self.continueSetup=NO;self.monitoring=NO;self.calibrating=NO;self.engine=nil;[self.central stopScan];if(self.target&&self.target.state!=CBPeripheralStateDisconnected)[self.central cancelPeripheralConnection:self.target];[self state:@"保护已暂停" detail:@"不会继续自动锁微信；已锁定的微信仍需手机确认解锁。"];[self note:@"监测已停止。"];[self updateControls];}
- (void)tick:(id)sender {
    if(!self.monitoring&&!self.calibrating)return;double now=Now();
    if(self.central.state==CBManagerStatePoweredOn&&self.target){
        if(self.target.state==CBPeripheralStateConnected&&now-self.lastRssiRequest>=3){self.lastRssiRequest=now;[self.target readRSSI];}
        else if(self.target.state==CBPeripheralStateDisconnected&&now-self.lastConnect>=12){self.lastConnect=now;[self.central connectPeripheral:self.target options:nil];}
        else if(self.target.state==CBPeripheralStateConnecting&&now-self.lastConnect>10)[self.central cancelPeripheralConnection:self.target];
    }
    NSDictionary *result=[[self.engine invokeMethod:@"tick" withArguments:@[@(now)]] toDictionary];
    if(!result||self.js.exception){[self stop:nil];[self state:@"状态机错误" detail:@"已停止监测，请反馈日志。"];return;}
    if(self.calibrating){
        if(now>self.calibrationDeadline){[self stop:nil];[self state:@"校验超时，尚未开启保护" detail:@"未能完成手机开／关对照；请检查设备选择。当前设备不一定支持此方案。"];return;}
        if(self.calibrationPhase==0&&[result[@"armed"] boolValue]){self.calibrationPhase=1;self.calibrationDeadline=now+180;[self state:@"校验 2/3：现在关闭手机蓝牙" detail:@"在 iPhone「设置 → 蓝牙」中关闭蓝牙，先不要打开。\n等页面提示“重新打开手机蓝牙”后再开启。Mac 蓝牙保持开启。"];[self note:@"已收到新信号；请关闭手机蓝牙，等页面提示后再打开。"];}
        else if(self.calibrationPhase==1&&[result[@"trigger"] boolValue]){self.calibrationPhase=2;self.calibrationDeadline=now+180;[self state:@"校验 3/3：现在重新打开手机蓝牙" detail:@"已检测到持续无信号。重新开启后，应看到同一个设备恢复。"];[self note:@"信号消失校验通过；等待同一设备恢复。"];}
        else if(self.calibrationPhase==2&&[result[@"state"] isEqual:@"near"]){self.calibrating=NO;self.calibrated=YES;self.engine=nil;[NSUserDefaults.standardUserDefaults setObject:NSDate.date forKey:@"verified"];[self saveProfile];[self state:@"手机已确认" detail:@"正在准备锁定验证。"];[self note:@"已完成新信号 → 消失 → 同一设备恢复校验。"];[self updateControls];if(self.continueSetup)[self start:nil];}
        return;
    }
    if([result[@"trigger"] boolValue])[self lockWeChat:NO];
    else if([result[@"state"] isEqual:@"near"]&&!self.lockBusy)[self state:@"保护已开启" detail:@"离开后自动锁定，返回请在手机上确认解锁。"];
    else if([result[@"state"] isEqual:@"countdown"]&&!self.lockBusy)[self state:@"手机信号中断" detail:[NSString stringWithFormat:@"若持续失联，约 %.0f 秒后尝试锁定。",MAX(0,self.delaySlider.integerValue-[result[@"elapsed"] doubleValue])]];
}
- (void)show:(id)sender {[NSApp activateIgnoringOtherApps:YES];[self.window makeKeyAndOrderFront:nil];}
- (BOOL)windowShouldClose:(NSWindow *)sender {[sender orderOut:nil];return NO;}
- (void)quit:(id)sender {if(self.lockBusy){[self alert:@"正在完成微信锁定操作，请稍后退出。"];return;}if(self.monitoring||self.calibrating){NSAlert *a=[NSAlert new];a.messageText=@"退出后不再保护微信，确定退出？";[a addButtonWithTitle:@"取消"];[a addButtonWithTitle:@"退出"];if([a runModal]!=NSAlertSecondButtonReturn)return;}[self stop:nil];[NSApp terminate:nil];}
- (void)applicationWillTerminate:(NSNotification *)n {[self.timer invalidate];[self.central stopScan];if(self.target)[self.central cancelPeripheralConnection:self.target];}
@end
int main(int argc,const char *argv[]) {@autoreleasepool{NSApplication *app=NSApplication.sharedApplication;[app setActivationPolicy:NSApplicationActivationPolicyRegular];Guard *guard=[Guard new];app.delegate=guard;[app run];}return 0;}
