config = {
    DEBUG = false,
    _VERSION = '0.01',
    ["mysql"] = {
        {
            ["hostname"] = "127.0.0.1",
            ["username"] = "root",
            ["password"] = "root",
            ["database"] = "max_dev",
            ["charset"] = "utf8",
            ["timeout"] = 2000,
            ["port"] = 3306
        },
        {
            ["hostname"] = "127.0.0.1",
            ["username"] = "root",
            ["password"] = "root",
            ["database"] = "max_test",
            ["charset"] = "utf8",
            ["timeout"] = 2000,
            ["port"] = 3306
        }
    },
}
return config