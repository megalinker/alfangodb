# AlfangoDB

AlfangoDB is a lightweight, modular database library implemented in Motoko, specifically designed for use on the Internet Computer (ICP). It supports comprehensive database operations including CRUD (Create, Read, Update, Delete), indexing, validation, and advanced filtering mechanisms.

## Features

* **Fully Typed**: Provides rigorous data typing ensuring data integrity.
* **CRUD Operations**: Comprehensive create, read, update, and delete functionalities.
* **Indexing and Uniqueness**: Supports attribute indexing and uniqueness constraints.
* **Advanced Filtering**: Offers a rich set of filtering expressions for querying.
* **Stable Serialization**: Ensures data consistency and efficient serialization/deserialization.
* **Modular Architecture**: Organized into clearly defined modules, enhancing maintainability.

## Structure

* `modules`: Core operational logic, such as create, read, update, delete, and search.
* `types`: Defines custom data types and interfaces.
* `utils`: Helper functions for serialization, hashing, and ID generation.
* `service`: Facade providing easy-to-use public interfaces for database operations.

## Getting Started

### Installation

Clone the repository and set up your environment:

```bash
git clone https://github.com/yourrepo/AlfangoDB.git
cd AlfangoDB
dfx start --background
```

### Usage

Instantiate your database:

```motoko
import AlfangoDB "./AlfangoDB/lib";

actor {
    stable let db = AlfangoDB.AlfangoDB();
}
```

### Creating a Database

```motoko
let result = AlfangoDB.createDatabase({
    createDatabaseInput = { name = "MyDatabase" };
    alfangoDB = db;
});
```

### Creating a Table

```motoko
let result = AlfangoDB.createTable({
    createTableInput = {
        databaseName = "MyDatabase";
        name = "Users";
        attributes = [
            { name = "username"; dataType = #text; unique = true; required = true; defaultValue = #default },
            { name = "age"; dataType = #int; unique = false; required = false; defaultValue = #default },
        ];
        indexes = [];
    };
    alfangoDB = db;
});
```

### Creating an Item

```motoko
let itemResult = await AlfangoDB.createItem({
    createItemInput = {
        databaseName = "MyDatabase";
        tableName = "Users";
        attributeDataValues = [
            ("username", #text("alice")),
            ("age", #int(30)),
        ];
    };
    alfangoDB = db;
});
```

## Examples

**Retrieve an item by ID:**

```motoko
let getResult = AlfangoDB.getItemById({
    getItemByIdInput = {
        databaseName = "MyDatabase";
        tableName = "Users";
        id = "some-item-id";
    };
    alfangoDB = db;
});
```

**Scanning with filters:**

```motoko
let scanResult = AlfangoDB.scan({
    scanInput = {
        databaseName = "MyDatabase";
        tableName = "Users";
        filterExpressions = [
            { attributeName = "age"; filterExpressionCondition = #GT(#int(25)) },
        ];
    };
    alfangoDB = db;
});
```

## Development and Testing

Run tests using:

```bash
dfx deploy
dfx canister call <your_canister> updateOperation '(your_input_here)'
```

## Contributions

Contributions are welcome! Please open an issue or submit a pull request.

## License

AlfangoDB is licensed under the MIT License. See [LICENSE](LICENSE) for details.
