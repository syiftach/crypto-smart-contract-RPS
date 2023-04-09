// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
    This contract lets players play rock-paper-scissors.
    its constructor receives a uint k which is the number of blocks mined before a reveal phase is over.
    
    players can send the contract money to fund their bets, see their balance and withdraw it, 
    as long as the amount is not in an active game.

    the game mechanics: 
    The players choose a gameId (some uint) that is not being currently used. 
    They then each call make_move() making a bet and committing to a move.
    in the next phase each of them reveals their committment, and once the second commit is done, the game is over. 
    The winner gets the amount of money they agreed on.    
    */



contract RPS{

    enum GameState {
        NO_GAME, //signifies that there is no game with this id (or there was and it is over)
        MOVE1, //signifies that a single move was entered
        MOVE2, //a second move was enetered
        REVEAL1, //one of the moves was revealed, and the reveal phase just started
        LATE // one of the moves was revealed, and enough blocks have been mined since such that the other player is considered late.
    } // These correspond to values 0,1,2,3,4

    enum Move{
        NONE, 
        ROCK, 
        PAPER, 
        SCISSORS
        } //These correspond to values 0,1,2,3

    /* game struct defines a RSP game instance */
    struct Game
    {
        uint gameId; // game ID
        GameState state; // current state of game
        address player1; // addr of player1
        address player2; // addr of player2
        bytes32 move1Hash; // commited hashed move of player1
        bytes32 move2Hash; // commited hashed move of player2
        Move move1; // move of player1
        Move move2; // move of player2
        uint betAmount; // amount of money each player placed as a bet
        uint blockNumber; // number of block mined that includes player1's reveald move
        address firstRevealer; // addr of player to first reveal his move
        }

    // number of blocks mined, after which first revealer can cancel game (LATE)
    uint public periodLength;
    // maps every gameID to its corresponding Game struct
    mapping(uint=>Game) public games;
    // maps player addr to its account in this contract
    mapping(address=>uint) public playersAccount;
    // mapping from player to its locked deposit in contract
    mapping(address=>uint) public lockedDeposits;


    /**
    Constructs a new contract that allows users to play multiple rock-paper-scissors games. 
    If one of the players does not reveal the move committed to, then the _reveal_period_length 
    is the number of blocks that a player needs to wait from the moment of revealing her move until 
    she can calim that the other player loses (for not revealing).
    The reveal_period_length must be at least 1 block.
    */
    constructor(uint _reveal_period_length)
    {
        require(_reveal_period_length >= 1, "period should be at least 1 block");
        periodLength=_reveal_period_length;
    }

    /**
    // A utility function that can be used to check commitments. See also commit.py.
    */
    function check_commitment(bytes32 commitment, Move move, bytes32 key) pure public returns(bool)
    {
        // python code to generate the commitment is:
        //  commitment = HexBytes(Web3.solidityKeccak(['int256', 'bytes32'], [move, key]))
        return keccak256(abi.encodePacked(uint(move),key)) == commitment;
    }

    /**
    // Returns the state of the game at the current address as a GameState (see enum definition)
    */
    function get_game_state(uint gameId) external view returns(GameState)
    {
        // if one of the players revealed his move, and wait period was ended
        if (games[gameId].firstRevealer != address(0) && 
        (block.number - games[gameId].blockNumber) > periodLength && 
        games[gameId].state == GameState.REVEAL1) 
        {
            // set the game state to LATE
            return GameState.LATE;
        }
        return games[gameId].state;
    }

    /**
    // The first call to this function starts the game. The second call finishes the commit phase. 
    // The amount is the amount of money (in wei) that a user is willing to bet. 
    // The amount provided in the call by the second player is ignored, but the user must have an amount matching that of the game to bet.
    // amounts that are wagered are locked for the duration of the game.
    // A player should not be allowed to enter a commitment twice. 
    // If two moves have already been entered, then this call reverts.
    */
    function make_move(uint gameId, uint bet_amount, bytes32 hidden_move) external
    {
        
        // starting new game: msg sender is player1 (first move of the game)
        // the first player to call this function is player1
        if (games[gameId].state==GameState.NO_GAME)
        {
            // check that the player place a positive bet
            // require(bet_amount>0, "bet amount should be >0");
            // check that there is enough money in account
            require(playersAccount[msg.sender]>=bet_amount,"not enough money in player account");
            // check that player has not committed twice
            require(games[gameId].player1 == address(0), "failed to make move: player cannot commit twice");

            // set parameters
            games[gameId].state=GameState.MOVE1;
            games[gameId].gameId=gameId;
            games[gameId].betAmount=bet_amount;
            games[gameId].move1Hash=hidden_move;
            games[gameId].player1=msg.sender;
            // lock amount in player's deposit
            depositBet(msg.sender,bet_amount);
        }

        // player2 is making his first move (second move of the game)
        // the second player to call this function is player2 (cannot be player1)
        else if (games[gameId].state==GameState.MOVE1)
        {
            // check that there is enough money in account
            require(playersAccount[msg.sender] >= games[gameId].betAmount,"not enough money in player account");
             // check that player has not committed twice
            require(msg.sender != games[gameId].player1, "failed to make move: player cannot commit twice");
            require(games[gameId].player2 == address(0), "failed to make move: player cannot commit twice");

            // set parameters
            games[gameId].state=GameState.MOVE2;
            games[gameId].move2Hash=hidden_move;
            games[gameId].player2=msg.sender;
            // lock amount in player's deposit: given bet amount is ignored
            depositBet(msg.sender,games[gameId].betAmount);
        }

        // revert if both players commited their move
        else
        {
            revert("failed to make move: requied moves already commited for this game");
        }
    }

    /**
    This function allows a player to cancel the game, but only if the other player did not yet commit to his move. 
    a canceled game returns the funds to the player. 
    Only the player that made the first move can call this function, and it will run only if no other commitment for a move was entered. 
    */
    function cancel_game(uint gameId) external gameActive(gameId) calledByP1(gameId) 
    {
        // end the game and return bet amounts to players
        require(games[gameId].state==GameState.MOVE1, "game cannot be canceled");
        require(games[gameId].player2==address(0), "player2 already commited his move");
        // update player1 account: draw bet back to his account
        drawBet(games[gameId].player1, games[gameId].betAmount);
        // delete game struct and free gameID
        delete games[gameId];

        // test betAmount==0
        // assert(games[gameId].betAmount<=lockedDeposits[games[gameId].player1]);
        // assert(games[gameId].betAmount<=lockedDeposits[games[gameId].player2]);
    }

    /**
    // Reveals the move of a player (which is checked against his commitment using the key)
    // The first call to this function can be made only after two moves have been entered (otherwise the function reverts).
    // This call will begin the reveal period.
    // the second call (if called by the player that entered the second move) reveals her move, ends the game, and awards the money to the winner.
    // if a player has already revealed, and calls this function again, then this call reverts.
    // only players that have committed a move may reveal.
    */
    function reveal_move(uint gameId, Move move, bytes32 key) external
    {
        // if player1 is first to reveal his move
        if (games[gameId].player1==msg.sender && games[gameId].state==GameState.MOVE2)
        {
            // verify commitment
            require(check_commitment(games[gameId].move1Hash,move,key),"failed to verify commitment");
            // check that player is not trying to reveal twice
            require(games[gameId].move1==Move.NONE, "cannot reveal move twice");

            // update the game status
            games[gameId].move1=move;
            games[gameId].state=GameState.REVEAL1;
            games[gameId].blockNumber=block.number; // set block number to check for timeout later 
            games[gameId].firstRevealer=msg.sender; //set player1 to be the first revealer
        }
        // if player1 is second to reveal his move: end the game
        else if (games[gameId].player1==msg.sender && games[gameId].state==GameState.REVEAL1)
        {
            require(check_commitment(games[gameId].move1Hash,move,key),"failed to verify commitment");
            require(games[gameId].move1==Move.NONE, "cannot reveal move twice");

            // update the game status
            games[gameId].move1=move;
            games[gameId].state=GameState.NO_GAME;
            // compute game result
            endGame(games[gameId]);
            // free gameID
            delete games[gameId];
        }
        // if player2 is first to reveal his move
        else if (games[gameId].player2==msg.sender && games[gameId].state==GameState.MOVE2)
        {
            require(check_commitment(games[gameId].move2Hash,move,key),"failed to verify commitment");
            require(games[gameId].move2==Move.NONE, "cannot reveal move twice");

            // update the game status
            games[gameId].move2=move;
            games[gameId].state=GameState.REVEAL1;
            games[gameId].blockNumber=block.number; // set block number to check for timeout later 
            games[gameId].firstRevealer=msg.sender; //set player2 to be the first revealer
        }
        // if player2 is second to reveal his move: end the game
        else if (games[gameId].player2==msg.sender && games[gameId].state==GameState.REVEAL1)
        {
            require(check_commitment(games[gameId].move2Hash,move,key),"failed to verify commitment");
            require(games[gameId].move2==Move.NONE, "cannot reveal move twice");

            // update the game status
            games[gameId].move2=move;
            games[gameId].state=GameState.NO_GAME;
            // compute game result
            endGame(games[gameId]);
            // free gameID
            delete games[gameId];
        }
        // can only reveal if both players commited a move
        else
        {
            revert("failed to reveal move");
        }
    }

    /**
    // If no second reveal is made, and the reveal period ends, the player that did reveal can claim all funds wagered in this game.
    // The game then ends, and the game id is released (and can be reused in another game). 
    // this function can only be called by the first revealer. If the reveal phase is not over, this function reverts.
    */
    function reveal_phase_ended(uint gameId) external gameActive(gameId) 
    {
        // check if first player revealed his move
        require(games[gameId].firstRevealer != address(0), "no move was revealed for this game");
        // check for timeout
        require((block.number - games[gameId].blockNumber) > periodLength, "reveal phase has not ended yet");
        // check for caller: should be the first player to reveal his move
        require(msg.sender==games[gameId].firstRevealer,"only the player to first reveal his move can call this function");
        
        // first player to reveal his move is considered the winner of the game
        if (msg.sender==games[gameId].player1)
        {
            updateResults(games[gameId], games[gameId].player1, games[gameId].player2);
        }
        else if (msg.sender==games[gameId].player2)
        {
            updateResults(games[gameId], games[gameId].player2, games[gameId].player1);
        }
        else
        {
            revert("error occuored");
        }
        // free the game id
        delete games[gameId];

        // assert(games[gameId].player1==address(0));
        // assert(games[gameId].player2==address(0));
    }

    /* ============================================ HANDLE_MONEY ============================================*/

    /**
    returns the balance of the given player. 
    Funds that are wagered in games that did not complete yet are not counted as part of the balance.
    */
    function balanceOf(address player) external view returns(uint)
    {
        return playersAccount[player];
    }

    /**
    // Withdraws amount from the account of the sender 
    // (available funds are those that were deposited or won but not currently staked in a game).
    */
    function withdraw(uint amount) external
    {
        // validate conditions
        require(playersAccount[msg.sender] > 0,"no money in deposit for caller");
        require(amount > 0 ,"amount must be positive");
        require(playersAccount[msg.sender] >= amount ,"given amount is greater then amount in account");

        // update changes
        playersAccount[msg.sender]-=amount;

        // commit changes
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "failed to send ether");
    }

    /**
    // adds eth to the account of the message sender.
    */
    receive() external payable 
    {
        playersAccount[msg.sender]+=msg.value;
    }



    fallback() external payable 
    {
        playersAccount[msg.sender]+=msg.value;
    }

    /* ============================================ HELPER_FUNCTIONS ============================================*/

    function getContractBalance() public view returns (uint)
    {
        return address(this).balance;
    }

    function getMoveHash(uint move,bytes32 key) public pure returns(bytes32)
    {
        return keccak256(abi.encodePacked(move,bytes32(key)));
    }

    function getCurrentBlockNumber() public view returns(uint)
    {
        return block.number;
    }

    function getLocketDeposit(address player) public view returns(uint)
    {
        return lockedDeposits[player];
    }

    function depositBet(address player, uint amount) internal 
    {
        playersAccount[player]-=amount;
        lockedDeposits[player]+=amount;
        assert(playersAccount[player]>=0);
        assert(lockedDeposits[player]>=0);
    }

    function drawBet(address player, uint amount) internal 
    {
        playersAccount[player]+=amount;
        lockedDeposits[player]-=amount;
        assert(playersAccount[player]>=0);
        assert(lockedDeposits[player]>=0);
    }

    function endGame(Game memory game) internal 
    {

        // tie scenario: return deposits to players
        if (game.move1==game.move2)
        {
            drawBet(game.player1, game.betAmount);
            drawBet(game.player2, game.betAmount);
        }
        // player1 winning scenraios
        else if ((game.move1==Move.ROCK && game.move2==Move.SCISSORS) || 
                (game.move1==Move.PAPER && game.move2==Move.ROCK) ||
                (game.move1==Move.SCISSORS && game.move2==Move.PAPER))
                
        {
            updateResults(game,game.player1,game.player2);
        }
        // player2 winning scenraios
        else if ((game.move2==Move.ROCK && game.move1==Move.SCISSORS) || 
                (game.move2==Move.PAPER && game.move1==Move.ROCK) ||
                (game.move2==Move.SCISSORS && game.move1==Move.PAPER))
        {
            updateResults(game,game.player2,game.player1);
        }
        // only player1 chose illegal move: player2 is considered the winner of the game
        else if ( (uint(game.move1) == 0 || uint(game.move1) > 3) && (uint(game.move2) > 0 && uint(game.move2) <= 3) )
        {
            updateResults(game, game.player2, game.player1);
        }
        // only player2 chose illegal move: player1 is considered the winner of the game
        else if ( (uint(game.move2) == 0 || uint(game.move2) > 3) && (uint(game.move1) > 0 && uint(game.move1) <= 3) )
        {
            updateResults(game, game.player1 ,game.player2);
        }
        // both players chose illegal move: revert the game
        else if ( (uint(game.move1) == 0 || uint(game.move1) > 3) && (uint(game.move2) == 0 || uint(game.move2) > 3) )
        {
            drawBet(game.player1, game.betAmount);
            drawBet(game.player2, game.betAmount);
        }
        else
        {
            revert("ERROR: RPS.endGame() failed to end the game");
        }
        
    }

    function updateResults(Game memory game, address winner, address loser) internal 
    {
        // require(msg.sender==address(this),"only contract can call this function");
        // unlock deposits
        lockedDeposits[winner] -= game.betAmount;
        lockedDeposits[loser] -= game.betAmount;
        // transer deposit to winner
        playersAccount[winner] += (game.betAmount * 2);
    }


    



    /* ============================================ MODIFIERS ============================================*/

    modifier gameActive(uint gameId) 
    {
        bool status = (games[gameId].state != GameState.NO_GAME);
        require(status, "ERROR: game does not exists or game has ended");
        _;
    }

    modifier calledByP1(uint gameId) 
    {
        require(msg.sender==games[gameId].player1, "only player1 can call this function");
        _;
    }


}
