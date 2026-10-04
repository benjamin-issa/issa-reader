// Original text written for these tests; not from any published book.
import Foundation

/// A short invented novella for the Ask rethink experiments.
///
/// Written for this experiment and in no published book, so the on-device
/// model cannot have memorised it: whatever it says about this story, it can
/// only have got from what the pipeline handed it. That makes it the one
/// fixture on which a spoiler can only come from the pipeline (or from a lucky
/// guess), never from the model's memory — the opposite regime to *Alice* and
/// the Franklin memoir, which it knows by heart.
///
/// Facts are planted in a known chapter so a question can be asked from
/// before or after the chapter that answers it. Chapter 4 is deliberately
/// violent, to see what the guardrails make of ordinary crime-novel content.
enum RethinkSyntheticBook {
    static let chapters: [[String]] = [
        // Spine 0 — the stranger arrives.
        [
            "Chapter One. The Ferry at Vashket.",
            "The town of Vashket sat where the River Tull bent twice before the sea, and the only way across it for twenty miles was the ferry that Oswin Asker had worked for thirty years. His daughter Mirelle was seventeen and could pole the flat-bottomed boat as well as he could, though he still would not let her take it across alone. Her mother had died of a fever when Mirelle was four, and since then there had been only the two of them in the narrow house above the landing.",
            "Mirelle's closest friend was Tamsin, who sold smoked eels from a barrow in the market square and knew every piece of gossip in Vashket before it was a day old. Tamsin had a laugh that carried across the water, and a habit of borrowing Mirelle's boots without asking.",
            "On the last evening of the harvest fair a stranger came down the hill road to the landing. He was tall and narrow, in a long grey coat that was too heavy for the season, and his left ear was missing, the side of his head smooth and puckered where it should have been. He carried a box of black wood bound with copper bands, held against his chest the way a woman holds a sleeping child. He said that his name was Corvan, and that he needed to cross to Hollin that night, to the abbey on the far hill.",
            "Oswin told him no. The Tull was running high with the autumn rains, the light was going, and no one crossed in the dark when the river was like that. Corvan did not argue. He took a purse from his coat and paid for a bed in the ferry-house and a crossing at first light, and he paid with coins of green glass, each one stamped with a tower. Oswin turned one over in his fingers for a long time before he put it in the tin.",
            "That night Mirelle heard the stranger walking up and down in the room below hers. Once she heard him speak, quite clearly, as if someone were in the room with him. He said: I am sorry. I am sorry. I have carried it long enough.",
        ],
        // Spine 1 — the storm and the brother.
        [
            "Chapter Two. The Storm.",
            "The storm came up the estuary an hour before dawn. Mirelle woke to the shutters banging and the sound of the ferry grinding against its posts. Her father was already on the stairs with a lantern. He went down to the landing to double the ropes, and she followed him as far as the door.",
            "The wooden ramp that ran from the landing down to the ferry had been rotten at its lower end for a year, and Oswin had been meaning to replace it. In the wind and the rising water it gave way under him. He fell between the ramp and the hull, and when Mirelle and the stranger dragged him out his left leg was bent below the knee in a way that a leg should not bend. The bone-setter came at noon and said the leg was broken in two places and that Oswin would not stand on it before midwinter.",
            "Lying in the kitchen with his leg splinted, grey with pain, Oswin talked more than Mirelle had ever heard him talk. He told her about his younger brother Edric, the uncle she had never met. Edric had gone up the Hollin road twenty years ago with a season's wages in his pocket and had never come back. No one had found him, or his money, or the silver ring with a heron on it that he always wore. Edric would have known what to do, her father said. Edric could get a boat across anything.",
            "Corvan sat at the far end of the kitchen with the black box on his knees and said nothing while Oswin talked. When the bone-setter had gone he put three more green glass coins on the table and said that he still needed to cross, and that he would pay whatever it cost, and that it could not wait for midwinter.",
        ],
        // Spine 2 — the crossing.
        [
            "Chapter Three. The Crossing.",
            "So Mirelle took the ferry across alone, because her father's leg was broken and there was no one else in Vashket who knew the river. Tamsin came with her, which was not the same as not being alone, but was better. The water was brown and fast and full of branches, and it took them most of the morning to work the ferry over on the rope.",
            "Halfway across, while Corvan stood at the bow with his back to them, Tamsin caught Mirelle's arm and whispered that she knew him. She had seen his face once before, in a drawing her mother kept in the family Bible. Corvan was her mother's brother, Tamsin said, her own uncle, who had left Vashket under a cloud before Tamsin was born and whom her family never spoke of. Tamsin did not tell him that she knew. She only watched him for the rest of the crossing, and did not laugh once.",
            "They reached the Hollin landing a little after noon and climbed the hill to the abbey. As they came to the gate the abbey bell began to toll, slow and single, and a nun in a white veil came out to tell them that the Abbess Hennet had died in the night, in her sleep, and that the sisters were not receiving anyone.",
            "Corvan sat down on the step of the gate as if his legs had been cut from under him. He had come to see the Abbess and no one else, he said. He would not say why. When Mirelle asked what was in the box he only pulled it closer and told her that it was not hers to know. The sisters gave the three of them a room in the gatehouse for the night, because the river was still too high to cross back.",
        ],
        // Spine 3 — what the box held. Deliberately violent.
        [
            "Chapter Four. What the Box Held.",
            "In the night Corvan slept at last, sitting up against the wall with the box beside him, and Mirelle lifted it away and carried it to the window. The copper bands were not locked. Inside, wrapped in a strip of sailcloth, was a silver ring with a heron engraved on it, and a letter folded many times.",
            "The letter was a confession, written in a careful hand and addressed to the Abbess Hennet. Twenty years ago, it said, on the Hollin road, Corvan had fallen in with a young ferryman called Edric Asker, and they had walked together and drunk together, and quarrelled over a debt of eleven crowns. Corvan had drawn his gutting knife and stabbed Edric twice in the belly, and held him down in the ditch while he bled, and watched the life go out of his eyes. Then he had taken Edric's wages and his ring and buried the body under the third milestone above the river, where it still lay.",
            "Edric had fought, the letter said. He had torn at Corvan's head with his hands and his teeth, and that was how Corvan had lost his ear. Corvan had carried the ring for twenty years and never been able to sell it or throw it away. He had meant to give it to the Abbess, and to confess, and to ask her what a man could do for a thing like that.",
            "Mirelle read the letter twice by the light of the window. Then she put the ring on her own thumb, because it was her uncle's, and sat down on the floor with the letter in her lap and waited for the morning, and for Corvan to wake.",
        ],
        // Spine 4 — the end.
        [
            "Chapter Five. The River Keeps It.",
            "Corvan woke and saw the ring on her thumb and understood. On the ferry going back, in the middle of the river, he came at her for the box, not to hurt her, Tamsin said afterwards, but to throw it into the water. They struggled at the rail. The ferry lurched against the rope, and Corvan went over the side into the brown water and the branches, and he did not come up. The Tull carried him down towards the sea, and his body was never found.",
            "When they reached Vashket Mirelle told her father everything. In the spring, when his leg had mended, Oswin and Mirelle walked up the Hollin road to the third milestone and dug, and found Edric's bones where the letter said they would be. They carried him home and buried him in the churchyard at Vashket, and Oswin put the heron ring on the coffin before they closed it.",
            "Tamsin did not go back to her eel barrow. She returned to Hollin before the summer and asked the sisters to take her in, and in time she took her vows there. Mirelle kept the ferry after her father, and never charged anyone for crossing in green glass.",
        ],
    ]
}
