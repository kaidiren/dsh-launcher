// 输出屏幕可用区域（去掉菜单栏/Dock），格式：left,top,right,bottom
// 坐标系转换为 AppleScript 窗口 bounds 所用的左上原点。
import Cocoa
guard let s = NSScreen.main else { print("0,38,1200,800"); exit(0) }
let f = s.frame
let v = s.visibleFrame
let top = f.height - (v.origin.y + v.height)
let bottom = f.height - v.origin.y
print("\(Int(v.origin.x)),\(Int(top)),\(Int(v.origin.x + v.width)),\(Int(bottom))")
