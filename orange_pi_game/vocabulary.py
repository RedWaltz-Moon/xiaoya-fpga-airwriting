"""常用生活词库：只维护词与中文释义，不涉及识别模型、串口或出题状态。

按生活主题编排便于校对；游戏仍只有数字、单词、混写三个入口。
3～4字母用于基础练习，较长词随通关进度逐步出现；大写为规范键，题目首字母大写、其余小写。
"""

from .vocabulary_cet import CET_WORD_MEANINGS

WORD_MEANINGS = {
    # 动物：常见动物、昆虫及幼小动物。
    "CAT": "猫", "DOG": "狗", "PIG": "猪", "COW": "牛",
    "FOX": "狐狸", "HEN": "母鸡", "ANT": "蚂蚁", "BEE": "蜜蜂",
    "FISH": "鱼", "BIRD": "鸟", "DUCK": "鸭子", "OWL": "猫头鹰",
    "BAT": "蝙蝠", "BUG": "小虫", "LION": "狮子", "BEAR": "熊",
    "DEER": "鹿", "FROG": "青蛙", "WOLF": "狼", "GOAT": "山羊",
    "LAMB": "小羊", "SEAL": "海豹", "CRAB": "螃蟹", "SWAN": "天鹅",
    "WORM": "蠕虫", "HORSE": "马", "TIGER": "老虎", "PANDA": "熊猫",
    "ZEBRA": "斑马", "MOUSE": "老鼠", "SHEEP": "绵羊", "GOOSE": "鹅",
    "SNAKE": "蛇", "SHARK": "鲨鱼", "WHALE": "鲸", "CAMEL": "骆驼",
    "SNAIL": "蜗牛", "CHICK": "小鸡", "PUPPY": "小狗", "BUNNY": "小兔",
    "RABBIT": "兔子", "MONKEY": "猴子", "TURTLE": "乌龟", "PARROT": "鹦鹉",
    # 食物：水果、蔬菜、主食与常见饮品。
    "CAKE": "蛋糕", "MILK": "牛奶", "RICE": "米饭", "SOUP": "汤",
    "EGG": "鸡蛋", "BEAN": "豆子", "PEAR": "梨", "PLUM": "李子",
    "CORN": "玉米", "JAM": "果酱", "NUT": "坚果", "MEAT": "肉",
    "APPLE": "苹果", "BANANA": "香蕉", "ORANGE": "橙子", "GRAPE": "葡萄",
    "LEMON": "柠檬", "MANGO": "芒果", "MELON": "瓜", "PEACH": "桃子",
    "BERRY": "浆果", "CHERRY": "樱桃", "TOMATO": "番茄", "CARROT": "胡萝卜",
    "POTATO": "土豆", "ONION": "洋葱", "SALAD": "沙拉", "BREAD": "面包",
    "HONEY": "蜂蜜", "CANDY": "糖果", "SUGAR": "糖", "JUICE": "果汁",
    "CHEESE": "奶酪", "COOKIE": "小饼干", "BUTTER": "黄油", "WATER": "水",
    # 身体：指向具体身体部位，不收录抽象医学词。
    "HEAD": "头", "FACE": "脸", "HAIR": "头发", "HAND": "手",
    "FOOT": "脚", "FEET": "双脚", "ARM": "手臂", "LEG": "腿",
    "TOE": "脚趾", "NOSE": "鼻子", "EYE": "眼睛", "EAR": "耳朵",
    "NECK": "脖子", "BACK": "背部", "KNEE": "膝盖", "SKIN": "皮肤",
    "MOUTH": "嘴", "TEETH": "牙齿（复数）", "TOOTH": "一颗牙齿", "THUMB": "拇指",
    # 家庭：家人、家具和餐具。
    "MOM": "妈妈", "DAD": "爸爸", "BABY": "婴儿", "HOME": "家",
    "ROOM": "房间", "DOOR": "门", "WALL": "墙", "ROOF": "屋顶",
    "BED": "床", "SOFA": "沙发", "LAMP": "台灯", "DESK": "书桌",
    "RUG": "小地毯", "CUP": "杯子", "BOWL": "碗", "FORK": "餐叉",
    "TABLE": "桌子", "CHAIR": "椅子", "FLOOR": "地板", "CLOCK": "时钟",
    "PHONE": "电话", "BRUSH": "刷子", "SPOON": "勺子", "PLATE": "盘子",
    "GLASS": "玻璃杯", "KNIFE": "餐刀", "TOWEL": "毛巾", "PILLOW": "枕头",
    "WINDOW": "窗户", "FAMILY": "家庭", "MOTHER": "母亲", "FATHER": "父亲",
    "SISTER": "姐妹",
    # 学习、玩具与衣物：与孩子日常接触的物品对应。
    "BOOK": "书", "PAGE": "书页", "WORD": "单词", "NAME": "名字",
    "PEN": "笔", "MAP": "地图", "BAG": "包", "BOX": "盒子",
    "HAT": "帽子", "CAP": "鸭舌帽", "COAT": "外套", "SHOE": "鞋子",
    "SOCK": "袜子", "DOLL": "玩偶", "BALL": "球", "TOY": "玩具",
    "GAME": "游戏", "KITE": "风筝", "GIFT": "礼物", "RING": "戒指",
    "PAPER": "纸", "PENCIL": "铅笔", "SCHOOL": "学校", "ERASER": "橡皮擦",
    "CRAYON": "蜡笔", "LETTER": "字母", "NUMBER": "数字", "PUZZLE": "拼图",
    "CIRCLE": "圆形", "BUTTON": "纽扣", "CAMERA": "相机", "SHIRT": "衬衫",
    # 自然、天气与颜色。
    "SUN": "太阳", "MOON": "月亮", "STAR": "星星", "SKY": "天空",
    "RAIN": "雨", "SNOW": "雪", "WIND": "风", "LEAF": "叶子",
    "TREE": "树", "ROCK": "岩石", "SAND": "沙子", "SEA": "海",
    "LAKE": "湖", "HILL": "小山", "SEED": "种子", "FARM": "农场",
    "RED": "红色", "BLUE": "蓝色", "PINK": "粉色", "GOLD": "金色",
    "GRAY": "灰色", "GREEN": "绿色", "WHITE": "白色", "BLACK": "黑色",
    "BROWN": "棕色", "GRASS": "草", "CLOUD": "云", "RIVER": "河流",
    "OCEAN": "海洋", "BEACH": "海滩", "STONE": "石头", "FIELD": "田野",
    "PLANT": "植物", "FLOWER": "花", "FOREST": "森林", "GARDEN": "花园",
    "SUMMER": "夏天", "WINTER": "冬天", "SPRING": "春天", "SUNNY": "晴朗的",
    "RAINY": "下雨的", "SNOWY": "下雪的", "WINDY": "多风的",
    # 常见动作：选择可演示或可用日常语境解释的动词。
    "RUN": "跑", "WALK": "走路", "JUMP": "跳", "HOP": "单脚跳",
    "SKIP": "蹦跳", "SWIM": "游泳", "SING": "唱歌", "READ": "阅读",
    "DRAW": "画画", "PLAY": "玩", "LOOK": "看", "HEAR": "听见",
    "HELP": "帮助", "WASH": "洗", "OPEN": "打开", "SHUT": "关上",
    "COME": "来", "STOP": "停下", "SIT": "坐", "EAT": "吃",
    "LOVE": "爱", "FIND": "找到", "GIVE": "给", "TAKE": "拿",
    "HOLD": "握住", "KICK": "踢", "RIDE": "骑", "HIDE": "躲藏",
    "COOK": "做饭", "CUT": "切", "WRITE": "书写", "PAINT": "绘画",
    "DANCE": "跳舞", "LAUGH": "笑", "SMILE": "微笑", "SLEEP": "睡觉",
    "DRINK": "喝", "CLEAN": "清洁", "WATCH": "观看", "LISTEN": "聆听",
    "LEARN": "学习", "CARRY": "携带", "THROW": "扔", "CATCH": "接住",
    "THINK": "思考", "TOUCH": "触摸", "COUNT": "数数", "CLIMB": "攀爬",
    "STAND": "站立",
    # 简单性质、位置与数词。
    "BIG": "大的", "TALL": "高的", "LONG": "长的", "FAST": "快的",
    "SLOW": "慢的", "HOT": "热的", "COLD": "冷的", "WARM": "温暖的",
    "COOL": "凉爽的", "SOFT": "软的", "HARD": "硬的", "KIND": "友善的",
    "GOOD": "好的", "NICE": "美好的", "SAFE": "安全的", "EASY": "容易的",
    "FULL": "满的", "WET": "湿的", "DRY": "干的", "NEW": "新的",
    "OLD": "旧的", "SAD": "伤心的", "LEFT": "左边", "SMALL": "小的",
    "SHORT": "短的", "HAPPY": "开心的", "QUIET": "安静的", "BRAVE": "勇敢的",
    "SWEET": "甜的", "ROUND": "圆的", "LIGHT": "轻的", "HEAVY": "重的",
    "EMPTY": "空的", "RIGHT": "右边", "UNDER": "在下面", "ABOVE": "在上面",
    "THREE": "三", "SEVEN": "七", "EIGHT": "八",
    # 出行：交通工具与常见道路词。
    "CAR": "汽车", "BUS": "公交车", "BOAT": "小船", "SHIP": "轮船",
    "BIKE": "自行车", "ROAD": "道路", "TAXI": "出租车", "TRAIN": "火车",
    "TRUCK": "卡车", "PLANE": "飞机", "WHEEL": "车轮", "STREET": "街道",
}

# 原有生活词及释义优先，保证扩词不会改写已经使用的基础词含义。
for word, meaning in CET_WORD_MEANINGS.items():
    WORD_MEANINGS.setdefault(word, meaning)

# 按同一张词义表派生词池和档案长度上限，长词不再被6字母门禁静默排除。
MAX_WORD_LENGTH = max(map(len, WORD_MEANINGS))
SHORT_WORDS = tuple(word for word in WORD_MEANINGS if 3 <= len(word) <= 4)
LONG_WORDS = tuple(word for word in WORD_MEANINGS if 5 <= len(word) <= MAX_WORD_LENGTH)
