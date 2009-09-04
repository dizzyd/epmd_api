

-record(epmd_node, { name,
                     port,
                     protocol = 0,
                     hidden = false,
                     high_vsn,
                     low_vsn,
                     extra = <<>> }).
