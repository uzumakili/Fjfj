"""把 src/ 裡的兩個腳本打包成 Roblox Studio 可以直接開啟的 LumenGarden.rbxlx。
改完腳本後執行：python build.py"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))


def read(name):
    with open(os.path.join(HERE, "src", name), encoding="utf-8") as f:
        src = f.read()
    if "]]>" in src:
        raise SystemExit(f"{name} 裡不能出現 ]]> 這串字")
    return src


def script(cls, ref, name, source):
    return (f'<Item class="{cls}" referent="{ref}"><Properties>'
            f'<string name="Name">{name}</string>'
            f'<ProtectedString name="Source"><![CDATA[{source}]]></ProtectedString>'
            f'</Properties></Item>')


def service(cls, ref, inner):
    return (f'<Item class="{cls}" referent="{ref}"><Properties>'
            f'<string name="Name">{cls}</string></Properties>{inner}</Item>')


xml = ('<roblox version="4">'
       + service("ServerScriptService", "RBX1",
                 script("Script", "RBX2", "LumenGarden", read("Garden.server.lua")))
       + service("StarterPlayer", "RBX3",
                 service("StarterPlayerScripts", "RBX4",
                         script("LocalScript", "RBX5", "LumenGardenUI", read("Garden.client.lua"))))
       + '</roblox>\n')

out = os.path.join(HERE, "LumenGarden.rbxlx")
with open(out, "w", encoding="utf-8", newline="\n") as f:
    f.write(xml)
print("已產生", out)
