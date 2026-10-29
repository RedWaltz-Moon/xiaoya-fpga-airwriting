"""原生分辨率绘图：在目标像素画布栅格化，不放大720p截图。"""


class NativeDraw:
    """统一换算逻辑坐标、线宽和圆角，按钮命中仍使用逻辑坐标。"""

    # 这里只负责逻辑坐标到原生画布像素的转换；窗口留黑边和反向命中由app处理。

    def __init__(self, pygame, scale):
        self.pg, self.scale = pygame, scale

    def point(self, value):
        return tuple(round(v * self.scale) for v in value)

    def rect_coords(self, value):
        x, y, w, h = value
        # 分别舍入两端边界，避免1.5倍缩放后相邻区域出现缝隙。
        left, top = self.point((x, y))
        right, bottom = self.point((x+w, y+h))
        return self.pg.Rect(left, top, right-left, bottom-top)

    def width(self, value):
        return max(1, round(value*self.scale)) if value else 0

    def rect(self, surface, color, rect, width=0, border_radius=0):
        return self.pg.draw.rect(surface, color, self.rect_coords(rect), self.width(width),
                                 border_radius=round(border_radius*self.scale))

    def circle(self, surface, color, center, radius, width=0):
        return self.pg.draw.circle(surface, color, self.point(center), round(radius*self.scale), self.width(width))

    def ellipse(self, surface, color, rect, width=0):
        return self.pg.draw.ellipse(surface, color, self.rect_coords(rect), self.width(width))

    def polygon(self, surface, color, points, width=0):
        return self.pg.draw.polygon(surface, color, [self.point(p) for p in points], self.width(width))

    def line(self, surface, color, start, end, width=1):
        return self.pg.draw.line(surface, color, self.point(start), self.point(end), self.width(width))

    def arc(self, surface, color, rect, start, stop, width=1):
        return self.pg.draw.arc(surface, color, self.rect_coords(rect), start, stop, self.width(width))

