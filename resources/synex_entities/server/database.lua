SynexEntityDatabase = {}

function SynexEntityDatabase.createOxmysqlAdapter(driver)
    assert(type(driver) == 'table', 'oxmysql driver table is required')
    assert(type(driver.query) == 'table' and type(driver.query.await) == 'function', 'oxmysql query.await is required')
    assert(type(driver.update) == 'table' and type(driver.update.await) == 'function', 'oxmysql update.await is required')

    return {
        query = function(statement, parameters)
            return driver.query.await(statement, parameters)
        end,
        update = function(statement, parameters)
            return driver.update.await(statement, parameters)
        end,
    }
end
