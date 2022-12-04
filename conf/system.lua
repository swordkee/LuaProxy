system = {
    ["mz"] = {
        tagID = "111111",
        token = "1111_token"
    },
    ["tcp"] = {
        jsonSchema = '{"type":"object","properties":{"host":{"type":"string"},"protocol":{"type":"string"},'
                .. '"port":{"type":"integer"},"method":{"type":"string","enum":["GET","POST"]},'
                .. '"timeout":{"type":"integer"},"path":{"type":"string"},"callBack":{"type":"string"},'
                .. '"proxy":{"type":"boolean"}},"required":["host","path"]}'
    }
}

return system